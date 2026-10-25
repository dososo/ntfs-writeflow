/*
 * ntfs_fskit.c - libntfs-3g logic behind the FSKit bridge.
 *
 * Pure C. Maps the nfsk_* C API (ntfs_fskit.h) onto libntfs-3g calls, mirroring
 * how ntfs-3g's src/ntfs-3g.c maps FUSE operations onto the same library.
 *
 * The block device is reached through a custom ntfs_device_operations whose
 * read/write call the nfsk_block_* functions implemented in ntfs_device_fskit.m.
 *
 * Compile with -DHAVE_CONFIG_H -I<ntfs-3g top> -I<ntfs-3g/include> so libntfs
 * struct layouts match the prebuilt libntfs-3g.a.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/disk.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/param.h>
#include <ntfs-3g/endians.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/index.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/bootsect.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/reparse.h>

#include "ntfs_fskit.h"

/* ---- Device context + operations backed by FSBlockDeviceResource ---- */
typedef struct nfsk_inode_ref {
    ntfs_inode *inode;
    struct nfsk_inode_ref *next;
} nfsk_inode_ref;

typedef struct nfsk_open_ref {
    MFT_REF ref;
    ntfschar *anchor;
    int anchor_length;
    bool open;
    struct nfsk_open_ref *next;
} nfsk_open_ref;

typedef struct {
    void    *resource;   /* __bridge FSBlockDeviceResource* (owned by Swift) */
    int64_t  pos;
    nfsk_inode_ref *inodes;
    nfsk_open_ref *open_items;
    uint64_t write_failures;
    int last_io_error;
    int writeback_error;
    int fatal_writeback_error;
} nfsk_devctx;

static int dev_open(struct ntfs_device *dev, int flags) {
    if (NDevOpen(dev)) { errno = EBUSY; return -1; }
    NDevSetBlock(dev);
    if ((flags & O_RDWR) != O_RDWR) NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int dev_close(struct ntfs_device *dev) {
    nfsk_devctx *c = dev->d_private;
    int ret = 0;
    if (!NDevOpen(dev)) { errno = EBADF; return -1; }
    if (NDevDirty(dev) && !NDevReadOnly(dev)) {
        int r = nfsk_block_sync(c->resource);
        if (r == 0) NDevClearDirty(dev);   /* only forget dirty once the flush succeeds */
        else { errno = -r; ret = -1; }      /* keep dirty so the failure isn't masked */
    }
    NDevClearOpen(dev);
    return ret;
}

static s64 dev_seek(struct ntfs_device *dev, s64 offset, int whence) {
    nfsk_devctx *c = dev->d_private;
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = c->pos; break;
        case SEEK_END: base = (int64_t)nfsk_block_total_bytes(c->resource); break;
        default: errno = EINVAL; return -1;
    }
    int64_t np = base + offset;
    if (np < 0) { errno = EINVAL; return -1; }
    c->pos = np;
    return np;
}

static s64 dev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    return nfsk_block_pread(c->resource, buf, offset, count);
}

static s64 record_write_result(nfsk_devctx *ctx, s64 result) {
    if (result < 0) {
        ctx->write_failures++;
        ctx->last_io_error = errno ? errno : EIO;
    }
    return result;
}

static s64 dev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    NDevSetDirty(dev);
    return record_write_result(c, nfsk_block_pwrite(c->resource, buf, offset, count));
}

static s64 dev_read(struct ntfs_device *dev, void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    s64 r = nfsk_block_pread(c->resource, buf, c->pos, count);
    if (r > 0) c->pos += r;
    return r;
}

static s64 dev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    NDevSetDirty(dev);
    s64 r = record_write_result(c, nfsk_block_pwrite(c->resource, buf, c->pos, count));
    if (r > 0) c->pos += r;
    return r;
}

static int dev_sync(struct ntfs_device *dev) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) return 0;
    int r = nfsk_block_sync(c->resource);
    if (r == 0) NDevClearDirty(dev);
    else { errno = -r; return -1; }
    return 0;
}

static int dev_stat(struct ntfs_device *dev, struct stat *buf) {
    nfsk_devctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFBLK | 0600;
    buf->st_size = (off_t)nfsk_block_total_bytes(c->resource);
    buf->st_blksize = (blksize_t)nfsk_block_sector_size(c->resource);
    if (buf->st_blksize > 0) buf->st_blocks = buf->st_size / buf->st_blksize;
    return 0;
}

static int dev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    nfsk_devctx *c = dev->d_private;
    switch (request) {
        case DKIOCGETBLOCKSIZE:
            *(uint32_t *)argp = nfsk_block_sector_size(c->resource);
            return 0;
        case DKIOCGETBLOCKCOUNT: {
            uint32_t s = nfsk_block_sector_size(c->resource);
            *(uint64_t *)argp = s ? nfsk_block_total_bytes(c->resource) / s : 0;
            return 0;
        }
        default: errno = ENOTTY; return -1;
    }
}

static struct ntfs_device_operations fskit_io_ops = {
    .open = dev_open, .close = dev_close, .seek = dev_seek,
    .read = dev_read, .write = dev_write, .pread = dev_pread, .pwrite = dev_pwrite,
    .sync = dev_sync, .stat = dev_stat, .ioctl = dev_ioctl,
};

/* ---- Volume wrapper + helpers ---- */
struct ntfs_fskit_volume {
    ntfs_volume *vol;
    nfsk_devctx *devctx;
    int          read_only;
};

static int nfsk_release_open_ref(ntfs_fskit_volume *v, nfsk_open_ref **slot);

static nfsk_devctx *volume_context(ntfs_volume *vol) { return vol->dev->d_private; }

/* Reserve ownership before opening: failed closes must retain their dirty inode.
 * Block new operations until synchronize retries it, avoiding duplicate live inodes. */
static ntfs_inode *nfsk_inode_open(ntfs_volume *vol, MFT_REF ref) {
    nfsk_devctx *ctx = volume_context(vol);
    if (ctx->writeback_error) { errno = ctx->writeback_error; return NULL; }
    nfsk_inode_ref *entry = calloc(1, sizeof(*entry));
    if (!entry) return NULL;
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
    if (!ni) { int saved = errno; free(entry); errno = saved; return NULL; }
    entry->inode = ni;
    entry->next = ctx->inodes;
    ctx->inodes = entry;
    return ni;
}

static void nfsk_forget_inode(ntfs_inode *ni) {
    nfsk_inode_ref **entry = &volume_context(ni->vol)->inodes;
    while (*entry && (*entry)->inode != ni) entry = &(*entry)->next;
    if (*entry) { nfsk_inode_ref *old = *entry; *entry = old->next; free(old); }
}

static int nfsk_real_close(ntfs_inode *ni) {
    nfsk_devctx *ctx = volume_context(ni->vol);
    uint64_t failures = ctx->write_failures;
    /* The library's index-context destructor does not propagate write errors.
     * Flush while we still own the inode, so its filename index can be retried. */
    int rc = ntfs_inode_sync(ni);
    if (rc || failures != ctx->write_failures) {
        int error = failures != ctx->write_failures ? ctx->last_io_error : (errno ? errno : EIO);
        NInoSetDirty(ni);
        NInoFileNameSetDirty(ni);
        errno = error;
        return -1;
    }
#if CACHE_NIDATA_SIZE
    // The caching close can retry/free an inode while still returning its first error.
    return ntfs_inode_real_close(ni);
#else
    return ntfs_inode_close(ni);
#endif
}

static int nfsk_inode_close(ntfs_inode *ni) {
    if (!ni) return 0;
    int saved = errno;
    nfsk_devctx *ctx = volume_context(ni->vol);
    nfsk_inode_ref **entry = &ctx->inodes;
    while (*entry && (*entry)->inode != ni) entry = &(*entry)->next;
    if (nfsk_real_close(ni)) {
        int error = errno ? errno : EIO;
        if (!ctx->writeback_error) ctx->writeback_error = error;
        errno = error;
        return -1;
    }
    if (*entry) { nfsk_inode_ref *old = *entry; *entry = old->next; free(old); }
    errno = saved;
    return 0;
}

static nfsk_open_ref *nfsk_open_ref_for(ntfs_volume *vol, MFT_REF ref) {
    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next)
        if (MREF(entry->ref) == MREF(ref)) return entry;
    return NULL;
}

static bool nfsk_unlinked_directory(ntfs_inode *dir) {
    nfsk_open_ref *entry = nfsk_open_ref_for(dir->vol, dir->mft_no);
    return entry && entry->anchor && le16_to_cpu(dir->mrec->link_count) == 1;
}

/* A WIN32/DOS name pair is removed by one ntfs_delete call. Its link_count is
 * two, but neither name keeps an open file alive after that deletion. */
static int nfsk_last_visible_link(ntfs_inode *ni) {
    unsigned links = le16_to_cpu(ni->mrec->link_count);
    if (links != 2) return links == 1;
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) return -1;
    int result = 0, error = 0;
    while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
        ATTR_RECORD *attr = search->attr;
        unsigned offset = le16_to_cpu(attr->value_offset), length = le32_to_cpu(attr->value_length);
        unsigned record = le32_to_cpu(attr->length);
        if (attr->non_resident || offset > record || length > record - offset || length < sizeof(FILE_NAME_ATTR)) {
            error = EIO; break;
        }
        FILE_NAME_ATTR *name = (FILE_NAME_ATTR *)((u8 *)attr + offset);
        if (name->file_name_type == FILE_NAME_DOS) { result = 1; break; }
    }
    if (!result && !error && errno != ENOENT) error = errno ? errno : EIO;
    ntfs_attr_put_search_ctx(search);
    if (error) { errno = error; return -1; }
    return result;
}

/* Keep an open item alive before deleting its last visible name. The root
 * anchor avoids preventing removal of the item's original parent directory. */
static int nfsk_preserve_open_item(ntfs_inode *ni, ntfs_inode *dir) {
    nfsk_open_ref *entry = nfsk_open_ref_for(ni->vol, ni->mft_no);
    if (!entry || !entry->open || entry->anchor) return 0;
    int last = nfsk_last_visible_link(ni);
    if (last <= 0) return last;
    if ((ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) && ntfs_check_empty_dir(ni)) return -1;
    ntfs_inode *root = dir->mft_no == FILE_root ? dir : nfsk_inode_open(ni->vol, FILE_root);
    if (!root) return -1;
    int error = EEXIST;
    for (int attempt = 0; attempt < 32; attempt++) {
        char name[96];
        snprintf(name, sizeof name, ".xntfs-open-%016llx-%08x%08x",
                 (unsigned long long)ni->mft_no, arc4random(), arc4random());
        ntfschar *unicode = NULL;
        int length = ntfs_mbstoucs(name, &unicode);
        if (length < 0) { error = errno ? errno : ENOMEM; break; }
        errno = 0;
        MFT_REF existing = ntfs_inode_lookup_by_name(root, unicode, length);
        if (existing != (MFT_REF)-1) { free(unicode); continue; }
        if (errno != ENOENT) { error = errno ? errno : EIO; free(unicode); break; }
        if (ntfs_link(ni, root, unicode, length)) {
            error = errno ? errno : EIO;
            free(unicode);
            break;
        }
        entry->anchor = unicode;
        entry->anchor_length = length;
        error = 0;
        break;
    }
    if (root != dir && nfsk_inode_close(root) && !error) error = errno ? errno : EIO;
    if (error) errno = error;
    return error ? -1 : 0;
}

static bool nfsk_is_retention_name(ntfs_volume *vol, uint64_t dir_mft,
                                  const ntfschar *name, int length) {
    if (dir_mft != FILE_root) return false;
    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next) {
        if (entry->anchor && ntfs_names_are_equal(entry->anchor, entry->anchor_length,
                name, length, IGNORE_CASE, vol->upcase, vol->upcase_len)) return true;
    }
    return false;
}

static int nfsk_delete(ntfs_volume *vol, ntfs_inode *ni, ntfs_inode *dir,
                       const ntfschar *name, int length) {
    if (nfsk_preserve_open_item(ni, dir)) {
        int saved = errno ? errno : EIO;
        nfsk_inode_close(ni);
        nfsk_inode_close(dir);
        errno = saved;
        return -1;
    }
    // ntfs_delete consumes both pointers, including on failure.
    nfsk_forget_inode(ni);
    nfsk_forget_inode(dir);
    int rc = ntfs_delete(vol, NULL, ni, dir, name, length);
    if (rc && (errno == EIO || errno == EBUSY || errno == ENOSPC)) {
        nfsk_devctx *ctx = volume_context(vol);
        // The namespace may already have changed. Never run a destructive rollback
        // or acknowledge a successful sync after an unrecoverable internal writeback.
        ctx->fatal_writeback_error = ctx->writeback_error = errno;
    }
    return rc;
}

static inline u64 to_mref(uint64_t ino) {
    return (ino == NFSK_ROOT_INO) ? (u64)FILE_root : (u64)ino;
}
static inline uint64_t from_mft(u64 mft_no) {
    return (mft_no == (u64)FILE_root) ? NFSK_ROOT_INO : (uint64_t)mft_no;
}

/* NTFS records 0..15 are reserved metadata ($MFT, $MFTMirr, $LogFile, $Volume,
 * $Bitmap, $Boot, $Extend, ...). FILE_root (5) is the visible root, remapped to
 * NFSK_ROOT_INO; every other sub-FILE_first_user record is metadata that must never
 * be exposed as a file — its raw MFT number also collides with reserved FSKit item
 * IDs ($MFT=0=invalid, $MFTMirr=1=parentOfRoot, $LogFile=2=root). */
static inline int is_reserved_mft(u64 mft_no) {
    return mft_no < (u64)FILE_first_user && mft_no != (u64)FILE_root;
}

/* Returns 1 = directory, 0 = non-directory, -1 = error (errno set). When the inode
 * is a directory and empty_out != NULL, *empty_out is set to 1 (empty) or 0 (not).
 * A real emptiness-probe failure (EIO/corruption — NOT "directory not empty") is
 * reported as -1 with errno, so it is never silently turned into ENOTEMPTY. */
static int nfsk_isdir(ntfs_volume *vol, u64 ref, int *empty_out) {
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) return -1;
    int isdir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    int ret = isdir, saved = 0;
    if (empty_out) {
        *empty_out = 1;
        if (isdir) {
            errno = 0;
            if (ntfs_check_empty_dir(ni) != 0) {
                if (errno == ENOTEMPTY) *empty_out = 0;
                else { ret = -1; saved = errno ? errno : EIO; }   /* real I/O error */
            }
        }
    }
    nfsk_inode_close(ni);
    if (ret == -1 && saved) errno = saved;
    return ret;
}

/* Raw parent MFT number from the inode's first FILE_NAME attribute, or (u64)-1 for
 * the root or when the record can't be read. */
static u64 nfsk_parent_mft_raw(ntfs_inode *ni) {
    if (ni->mft_no == (u64)FILE_root) return (u64)-1;
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) return (u64)-1;
    u64 pmft = (u64)-1;
    if (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, ctx)) {
        const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)
            ((const u8 *)ctx->attr + le16_to_cpu(ctx->attr->value_offset));
        pmft = MREF(le64_to_cpu(fn->parent_directory));
    }
    ntfs_attr_put_search_ctx(ctx);
    return pmft;
}

/* Parent directory (in our numbering) for attributes. NTFS hard links give one inode
 * several FILE_NAME attrs in different directories; we report the first — a stable,
 * deterministic choice — because FSKit identity is per fileID and cannot represent
 * multiple parents. Returns 0 when it can't be read (Swift then falls back to the
 * lookup hint, and enumeration overrides this with the listing directory). */
static uint64_t nfsk_parent_ino(ntfs_inode *ni) {
    if (ni->mft_no == (u64)FILE_root) return NFSK_PARENT_OF_ROOT;
    u64 pmft = nfsk_parent_mft_raw(ni);
    if (pmft == (u64)-1 || is_reserved_mft(pmft)) return 0;
    return from_mft(pmft);
}

/* Returns 1 if `sref` is `dst_dir` itself or an ancestor of it — i.e. moving the
 * directory `sref` into `dst_dir` would create a cycle (mv A A/B/C). 0 if not, -1 on
 * error (errno set). Walks dst_dir's FILE_NAME parent chain up toward the root. */
static int nfsk_dir_contains(ntfs_volume *vol, u64 sref, uint64_t dst_dir) {
    u64 cur = to_mref(dst_dir);
    for (int guard = 0; guard < 65536; guard++) {
        if (MREF(cur) == MREF(sref)) return 1;
        if (MREF(cur) == (u64)FILE_root) return 0;
        ntfs_inode *ni = nfsk_inode_open(vol, cur);
        if (!ni) return -1;                                /* errno from ntfs_inode_open */
        u64 par = nfsk_parent_mft_raw(ni);
        nfsk_inode_close(ni);                              /* clobbers errno, so set it below */
        if (par == (u64)-1) { errno = EIO; return -1; }    /* unreadable parent chain */
        cur = par;
    }
    errno = ELOOP;   /* chain too long → cyclic/corrupt metadata, not a real ancestry */
    return -1;
}

static uint32_t map_dt(unsigned dt_type) {
    switch (dt_type) {
        case NTFS_DT_DIR:     return NFSK_TYPE_DIR;
        /* Reparse links are classified separately after checking their target. */
        case NTFS_DT_LNK:     return NFSK_TYPE_FILE;
        case NTFS_DT_REPARSE: return NFSK_TYPE_FILE;
        case NTFS_DT_FIFO:    return NFSK_TYPE_FIFO;
        case NTFS_DT_SOCK:    return NFSK_TYPE_SOCKET;
        case NTFS_DT_BLK:     return NFSK_TYPE_BLOCKDEV;
        case NTFS_DT_CHR:     return NFSK_TYPE_CHARDEV;
        case NTFS_DT_REG:
        default:              return NFSK_TYPE_FILE;
    }
}

static struct ntfs_device *make_device(void *resource, nfsk_devctx **out_ctx) {
    nfsk_devctx *c = calloc(1, sizeof(*c));
    if (!c) { errno = ENOMEM; return NULL; }
    c->resource = resource;
    c->pos = 0;
    struct ntfs_device *dev = ntfs_device_alloc("ntfs-fskit", 0, &fskit_io_ops, c);
    if (!dev) { free(c); return NULL; }
    *out_ctx = c;
    return dev;
}

/* The durable NTFS volume serial: a 64-bit value in the boot sector at offset 0x48
 * (le64). ntfs-3g treats it as "Irrelevant" and doesn't cache it, so read it straight
 * from the backend. Used to give the volume a stable identity instead of a weak label+size
 * hash: the serial is immutable, so identity survives relabels and stays distinct between
 * independently-formatted same-label/same-size volumes. (A block-level clone copies the
 * serial, so clones intentionally share identity — inherent to any on-disk id.) */
static uint64_t read_boot_serial(void *resource) {
    unsigned char b[8];
    if (nfsk_block_pread(resource, b, 0x48, (int64_t)sizeof b) != (int64_t)sizeof b) return 0;
    uint64_t s = 0;
    for (int i = 0; i < 8; i++) s |= (uint64_t)b[i] << (8 * i);
    return s;
}

/* ---- Lifecycle ---- */
ntfs_fskit_volume *nfsk_mount(void *resource, bool read_only, int *out_errno) {
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) { if (out_errno) *out_errno = errno; return NULL; }

    ntfs_mount_flags flags = NTFS_MNT_MAY_RDONLY;
    if (read_only) flags |= NTFS_MNT_RDONLY;

    ntfs_volume *vol = ntfs_device_mount(dev, flags);
    if (!vol) {
        if (out_errno) *out_errno = errno ? errno : EIO;
        ntfs_device_free(dev);
        free(ctx);
        return NULL;
    }
    if (ntfs_volume_get_free_space(vol) || ntfs_set_ignore_case(vol)) {
        int saved = errno ? errno : EIO;
        ntfs_umount(vol, TRUE);
        free(ctx);
        if (out_errno) *out_errno = saved;
        return NULL;
    }
    /* ntfs_make_symlink/ntfs_get_abslink resolve an *absolute* reparse target relative to
     * vol->abs_mnt_point (the `mnt_point` arg is ignored — it's __attribute__((unused))).
     * ntfs_device_mount leaves abs_mnt_point NULL (only the FUSE layer sets it), so an
     * absolute Windows symlink/junction would strlen(NULL) and crash. Anchor it at "/"
     * (read-only literal; ntfs_get_abslink only reads it).
     * LIMITATION: the bridge can't know the real /Volumes/<name> mount point (FSKit assigns
     * it only after load), so an *absolute* Windows symlink/junction resolves best-effort
     * under "/" (e.g. //target or //.NTFS-3G/...), not the true volume path. RELATIVE symlinks
     * — the common POSIX case — are unaffected and resolve correctly. */
    vol->abs_mnt_point = "/";

    ntfs_fskit_volume *w = calloc(1, sizeof(*w));
    if (!w) { if (out_errno) *out_errno = ENOMEM; ntfs_umount(vol, TRUE); free(ctx); return NULL; }
    w->vol = vol;
    w->devctx = ctx;
    w->read_only = read_only || NVolReadOnly(vol);
    return w;
}

int nfsk_probe(void *resource, char *name_out, size_t name_cap, uint64_t *serial_out) {
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) return 0;
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) { ntfs_device_free(dev); free(ctx); return 0; }
    if (name_out && name_cap) {
        name_out[0] = '\0';
        if (vol->vol_name) { strncpy(name_out, vol->vol_name, name_cap - 1); name_out[name_cap - 1] = '\0'; }
    }
    ntfs_umount(vol, TRUE);
    /* Read the serial after umount so only this code touches the backend. */
    if (serial_out) *serial_out = read_boot_serial(resource);
    free(ctx);
    return 1;
}

int nfsk_quick_check(void *resource, int *reason) {
    if (reason) *reason = NFSK_CHECK_METADATA;
    if (!resource) return -EINVAL;
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) return -(errno ? errno : ENOMEM);

    /* This validates the boot sector, MFT/MFTMirr and core system files without
     * replaying or resetting the journal, even if the backend allows writes. */
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) {
        int error = errno ? errno : EIO;
        ntfs_device_free(dev);
        free(ctx);
        return -error;
    }

    int error = 0, diagnostic = NFSK_CHECK_CLEAN;
    ntfs_inode *log_inode = NULL;
    ntfs_attr *log_data = NULL;
    RESTART_PAGE_HEADER *restart = NULL;
    if (vol->flags & (VOLUME_IS_DIRTY | VOLUME_CHKDSK_UNDERWAY)) {
        diagnostic = NFSK_CHECK_DIRTY;
        error = EIO;
        goto done;
    }
    if (ntfs_volume_check_hiberfile(vol, 0)) {
        error = errno ? errno : EIO;
        diagnostic = error == EPERM ? NFSK_CHECK_HIBERNATED : NFSK_CHECK_METADATA;
        goto done;
    }
    log_inode = ntfs_inode_open(vol, FILE_LogFile);
    if (!log_inode) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
        goto done;
    }
    log_data = ntfs_attr_open(log_inode, AT_DATA, AT_UNNAMED, 0);
    if (!log_data) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
        goto done;
    }
    errno = 0;
    if (!ntfs_check_logfile(log_data, &restart) ||
        !ntfs_is_logfile_clean(log_data, restart) ||
        (restart && restart->major_ver == const_cpu_to_le16(2) &&
         restart->minor_ver == const_cpu_to_le16(0))) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
    }
done:
    free(restart);
    if (log_data) ntfs_attr_close(log_data);
    if (log_inode && ntfs_inode_close(log_inode) && !error) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_METADATA;
    }
    if (ntfs_umount(vol, TRUE) && !error) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_METADATA;
    }
    free(ctx);
    if (reason) *reason = diagnostic;
    return -error;
}

void nfsk_umount(ntfs_fskit_volume *v) {
    if (!v) return;
    while (v->devctx && v->devctx->open_items) {
        nfsk_open_ref *entry = v->devctx->open_items;
        uint64_t ino = from_mft(MREF(entry->ref));
        if (nfsk_close_item(v, ino)) {
            ntfs_log_error("xntfs: retaining an open-file recovery link after failed cleanup\n");
            v->devctx->open_items = entry->next;
            free(entry->anchor);
            free(entry);
        }
    }
    if (v->vol && nfsk_sync(v)) ntfs_log_error("xntfs: unmount after a writeback error\n");
    // A forced teardown cannot keep retrying an unavailable device. Report the
    // failure, then discard only the in-memory copies after the failed sync.
    while (v->devctx && v->devctx->inodes) {
        nfsk_inode_ref *entry = v->devctx->inodes;
        ntfs_inode *ni = entry->inode;
        NInoClearDirty(ni);
        NInoAttrListClearDirty(ni);
        NInoFileNameClearDirty(ni);
        for (int i = 0; i < ni->nr_extents; i++) {
            NInoClearDirty(ni->extent_nis[i]);
            NInoAttrListClearDirty(ni->extent_nis[i]);
            NInoFileNameClearDirty(ni->extent_nis[i]);
        }
        (void)nfsk_real_close(ni);
        v->devctx->inodes = entry->next;
        free(entry);
    }
    if (v->vol) ntfs_umount(v->vol, TRUE);
    free(v->devctx);
    free(v);
}

int nfsk_sync(ntfs_fskit_volume *v) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return 0;
    nfsk_devctx *ctx = v->devctx;
    int saved = ctx->writeback_error, current = ctx->fatal_writeback_error;
    nfsk_inode_ref **entry = &ctx->inodes;
    while (*entry) {
        nfsk_inode_ref *pending = *entry;
        if (nfsk_real_close(pending->inode)) {
            if (!current) current = errno ? errno : EIO;
            entry = &pending->next;
        } else {
            *entry = pending->next;
            free(pending);
        }
    }
    ctx->writeback_error = current;
    if (!current) {
        nfsk_open_ref **opened = &ctx->open_items;
        while (*opened) {
            if ((*opened)->open) { opened = &(*opened)->next; continue; }
            int rc = nfsk_release_open_ref(v, opened);
            if (rc) {
                if (!current) current = -rc;
                opened = &(*opened)->next;
            }
        }
    }
    ntfs_inode *metadata[] = { v->vol->lcnbmp_ni, v->vol->mft_ni,
                              v->vol->mftmirr_ni, v->vol->vol_ni, v->vol->secure_ni };
    for (size_t i = 0; i < sizeof(metadata) / sizeof(metadata[0]); i++) {
        if (metadata[i] && ntfs_inode_sync(metadata[i]) && !current) current = errno ? errno : EIO;
    }
    if (ntfs_device_sync(v->vol->dev) && !current) current = errno ? errno : EIO;
    ctx->writeback_error = current;
    return -(current ? current : saved);
}

int nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    ntfs_volume *vol = v->vol;
    memset(out, 0, sizeof(*out));
    out->cluster_size = vol->cluster_size;
    out->total_clusters = vol->nr_clusters;
    s64 freec = vol->free_clusters; if (freec < 0) freec = 0;
    out->free_clusters = (uint64_t)freec;
    if (vol->mftbmp_na) out->total_files = ((uint64_t)vol->mftbmp_na->allocated_size << 3);
    s64 freem = vol->free_mft_records; if (freem < 0) freem = 0;
    out->free_files = (uint64_t)freem;
    out->read_only = v->read_only ? 1 : 0;
    if (vol->vol_name) { strncpy(out->volume_name, vol->vol_name, sizeof(out->volume_name) - 1);
                         out->volume_name[sizeof(out->volume_name) - 1] = '\0'; }
    out->volume_serial = v->devctx ? read_boot_serial(v->devctx->resource) : 0;
    return 0;
}

/* ---- Attributes ---- */
static void fill_times(nfsk_attr_t *out, ntfs_inode *ni) {
    struct timespec ts;
    ts = ntfs2timespec(ni->last_data_change_time); out->mtime_sec = ts.tv_sec; out->mtime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->last_access_time);      out->atime_sec = ts.tv_sec; out->atime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->last_mft_change_time);  out->ctime_sec = ts.tv_sec; out->ctime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->creation_time);         out->btime_sec = ts.tv_sec; out->btime_nsec = ts.tv_nsec;
}

/* A reparse point counts as a symlink for us only when ntfs_make_symlink can actually
 * produce a target. ntfs_possible_symlink only checks the reparse tag, not the data, so a
 * junction / corrupt reparse with a symlink-ish tag would otherwise be typed SYMLINK yet
 * fail readlink afterwards; classifying by the real parse keeps the reported type in sync
 * with what readSymbolicLink can resolve. */
static char *nfsk_symlink_target(ntfs_inode *ni) {
    if (ni->flags & FILE_ATTR_REPARSE_POINT) return ntfs_make_symlink(ni, "/");
    if (!(ni->flags & FILE_ATTR_SYSTEM) || ntfs_interix_types(ni) != NTFS_DT_LNK) {
        errno = EINVAL;
        return NULL;
    }
    ntfs_attr *data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) return NULL;
    char *target = NULL;
    int error = EINVAL;
    size_t prefix = offsetof(INTX_FILE, target);
    if (data->data_size > (s64)prefix && data->data_size <= (s64)(prefix + 4096 * sizeof(ntfschar)) &&
        !((data->data_size - prefix) % sizeof(ntfschar))) {
        INTX_FILE *link = malloc((size_t)data->data_size);
        if (!link) error = ENOMEM;
        else {
            if (ntfs_attr_pread(data, 0, data->data_size, link) != data->data_size) error = errno ? errno : EIO;
            else if (link->magic == INTX_SYMBOLIC_LINK) {
                if (ntfs_ucstombs(link->target, (int)((data->data_size - prefix) / sizeof(ntfschar)), &target, 0) < 0)
                    error = errno ? errno : EILSEQ;
            }
            free(link);
        }
    }
    ntfs_attr_close(data);
    if (!target) errno = error;
    return target;
}

static uint32_t nfsk_inode_type(ntfs_inode *ni) {
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) return NFSK_TYPE_DIR;
    if (!(ni->flags & (FILE_ATTR_REPARSE_POINT | FILE_ATTR_SYSTEM))) return NFSK_TYPE_FILE;
    if (!(ni->flags & FILE_ATTR_REPARSE_POINT) && ntfs_interix_types(ni) != NTFS_DT_LNK)
        return map_dt(ntfs_interix_types(ni));
    char *target = nfsk_symlink_target(ni);
    if (!target) return 0;
    free(target);
    return NFSK_TYPE_SYMLINK;
}

int nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -ENOENT;   /* metadata is not a file */
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;

    memset(out, 0, sizeof(*out));
    out->ino = from_mft(ni->mft_no);
    out->parent_ino = nfsk_parent_ino(ni);
    out->nlink = le16_to_cpu(ni->mrec->link_count);
    nfsk_open_ref *opened = nfsk_open_ref_for(v->vol, ni->mft_no);
    if (opened && opened->anchor && out->nlink) out->nlink--;
    /* Formatters may mark the NTFS root HIDDEN | SYSTEM. Exposing HIDDEN here
     * hides the entire mounted volume in macOS, not just an ordinary item. */
    out->flags = ni->mft_no != FILE_root && (ni->flags & FILE_ATTR_HIDDEN) ? UF_HIDDEN : 0;

    uint32_t type = nfsk_inode_type(ni);
    if (type == NFSK_TYPE_DIR) {
        out->type = NFSK_TYPE_DIR;
        if (!test_nino_flag(ni, KnownSize)) {
            ntfs_attr *na = ntfs_attr_open(ni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4);
            if (na) { ni->data_size = na->data_size; ni->allocated_size = na->allocated_size;
                      set_nino_flag(ni, KnownSize); ntfs_attr_close(na); }
        }
        out->size = (uint64_t)ni->data_size;
        out->alloc_size = (uint64_t)ni->allocated_size;
        out->mode = 0777;
        if (out->nlink == 0 && !(opened && opened->anchor)) out->nlink = 1;
    } else if (type == NFSK_TYPE_SYMLINK) {
        /* Reparse points whose target actually parses are exposed as symlinks (so readlink
           works) with the POSIX symlink size = target string length; other tags
           (unresolvable junctions, dedup, ...) stay opaque regular files. */
        char *target = nfsk_symlink_target(ni);
        if (target) {
            out->type = NFSK_TYPE_SYMLINK;
            out->size = (uint64_t)strlen(target);
            out->alloc_size = out->size;
            out->mode = 0777;
            free(target);
        } else {
            out->type = NFSK_TYPE_FILE;
            out->size = (uint64_t)ni->data_size;
            out->alloc_size = (uint64_t)ni->allocated_size;
            out->mode = (ni->flags & FILE_ATTR_READONLY) ? 0444 : 0666;
        }
    } else {
        out->type = type ? type : NFSK_TYPE_FILE;
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) { out->size = (uint64_t)na->data_size;
                  out->alloc_size = (uint64_t)((na->data_flags & (ATTR_IS_SPARSE | ATTR_IS_COMPRESSED)) ? na->compressed_size : na->allocated_size);
                  ntfs_attr_close(na); }
        else    { out->size = (uint64_t)ni->data_size; out->alloc_size = (uint64_t)ni->allocated_size; }
        out->mode = (ni->flags & FILE_ATTR_READONLY) ? 0444 : 0666;
    }
    fill_times(out, ni);
    nfsk_inode_close(ni);
    return 0;
}

uint64_t nfsk_lookup(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, int *out_errno) {
    return nfsk_lookup_name(v, dir_ino, name_utf8, NULL, 0, out_errno);
}

uint64_t nfsk_lookup_name(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                          char *canonical_name, size_t capacity, int *out_errno) {
    if (!v || !v->vol || !name_utf8 || (canonical_name && !capacity)) {
        if (out_errno) *out_errno = EINVAL; return 0;
    }
    if (out_errno) *out_errno = 0;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; nfsk_inode_close(dir); return 0; }
    if (nfsk_is_retention_name(v->vol, dir->mft_no, uname, ulen)) {
        free(uname); nfsk_inode_close(dir);
        if (out_errno) *out_errno = ENOENT;
        return 0;
    }
    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    int saved = mref == (u64)-1 ? (errno ? errno : ENOENT) : 0;
    nfsk_inode_close(dir);
    if (!saved && is_reserved_mft(MREF(mref))) saved = ENOENT;
    if (!saved && canonical_name) {
        ntfs_inode *ni = nfsk_inode_open(v->vol, mref);
        if (!ni) saved = errno ? errno : EIO;
        else {
            ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
            if (!search) saved = errno ? errno : ENOMEM;
            else {
                saved = ENOENT;
                while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
                    const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)
                        ((const u8 *)search->attr + le16_to_cpu(search->attr->value_offset));
                    if (MREF(le64_to_cpu(fn->parent_directory)) != to_mref(dir_ino) ||
                        !ntfs_names_are_equal(fn->file_name, fn->file_name_length, uname, ulen,
                                              IGNORE_CASE, v->vol->upcase, v->vol->upcase_len)) continue;
                    char *text = NULL;
                    int length = ntfs_ucstombs(fn->file_name, fn->file_name_length, &text, 0);
                    if (length < 0) saved = errno ? errno : EILSEQ;
                    else if ((size_t)length >= capacity) saved = ENAMETOOLONG;
                    else { memcpy(canonical_name, text, length + 1); saved = 0; }
                    free(text);
                    if (saved || ntfs_names_are_equal(fn->file_name, fn->file_name_length, uname, ulen,
                                                      CASE_SENSITIVE, NULL, 0)) break;
                }
                if (errno != ENOENT && errno != 0 && saved == ENOENT) saved = errno;
                ntfs_attr_put_search_ctx(search);
            }
            nfsk_inode_close(ni);
        }
    }
    free(uname);
    if (saved) { if (out_errno) *out_errno = saved; return 0; }
    return from_mft(MREF(mref));
}

/* ---- Directory enumeration (robust ordinal cookies) ---- */
static int nfsk_directory_entry_type(ntfs_volume *vol, MFT_REF ref,
                                     FILE_ATTR_FLAGS flags, uint32_t *type) {
    *type = (flags & FILE_ATTR_I30_INDEX_PRESENT) ? NFSK_TYPE_DIR : NFSK_TYPE_FILE;
    if ((flags & FILE_ATTR_REPARSE_POINT) ||
        ((flags & FILE_ATTR_SYSTEM) && !(flags & FILE_ATTR_I30_INDEX_PRESENT))) {
        ntfs_inode *ni = nfsk_inode_open(vol, ref);
        if (!ni) return -(errno ? errno : EIO);
        *type = nfsk_inode_type(ni);
        if (!*type) *type = NFSK_TYPE_FILE;
        if (nfsk_inode_close(ni)) return -(errno ? errno : EIO);
    }
    return 0;
}

int nfsk_readdir(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie, void *ctx, nfsk_dir_cb cb) {
    if (!v || !v->vol || !cb) return -EINVAL;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    int saved = 0;
    ntfs_index_context *index = NULL;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { saved = ENOTDIR; goto out; }
    index = ntfs_index_ctx_get(dir, NTFS_INDEX_I30, 4);
    if (!index) { saved = errno ? errno : ENOMEM; goto out; }

    /* An empty filename sorts before all entries. ENOENT still returns its
     * insertion position. Read stored names from $I30: ntfs_readdir lowercases
     * them in ignore-case mode, which must stay enabled for all other operations. */
    FILE_NAME_ATTR first = {0};
    errno = 0;
    if (ntfs_index_lookup(&first, sizeof first, index) && errno != ENOENT) {
        saved = errno ? errno : EIO;
        goto out;
    }
    if (index->bad_index || !index->entry || !index->ir ||
        index->ir->type != AT_FILE_NAME || index->ir->collation_rule != COLLATION_FILE_NAME) {
        saved = EIO;
        goto out;
    }

    int64_t ordinal = 0, skip = start_cookie < 0 ? 0 : start_cookie;
    INDEX_ENTRY *entry = index->entry;
    while (entry) {
        if (!(entry->ie_flags & INDEX_ENTRY_END)) {
            size_t length = le16_to_cpu(entry->length), key_length = le16_to_cpu(entry->key_length);
            size_t overhead = offsetof(INDEX_ENTRY, key) +
                ((entry->ie_flags & INDEX_ENTRY_NODE) ? sizeof(VCN) : 0);
            if (length < overhead || key_length < offsetof(FILE_NAME_ATTR, file_name) ||
                key_length > length - overhead ||
                ntfs_index_entry_inconsistent(entry, COLLATION_FILE_NAME, dir->mft_no)) {
                saved = EIO;
                break;
            }
            const FILE_NAME_ATTR *fn = &entry->key.file_name;
            if (!fn->file_name_length || fn->file_name_type > FILE_NAME_WIN32_AND_DOS ||
                offsetof(FILE_NAME_ATTR, file_name) + fn->file_name_length * sizeof(ntfschar) > key_length) {
                saved = EIO;
                break;
            }
            MFT_REF ref = le64_to_cpu(entry->indexed_file);
            FILE_ATTR_FLAGS flags = fn->file_attributes;
            if (fn->file_name_type == FILE_NAME_DOS || MREF(ref) < FILE_first_user ||
                ((flags & FILE_ATTR_HIDDEN) && !NVolShowHidFiles(v->vol))) goto next_entry;
            if (nfsk_is_retention_name(v->vol, dir->mft_no, fn->file_name, fn->file_name_length)) goto next_entry;

            char *name = NULL;
            if (ntfs_ucstombs(fn->file_name, fn->file_name_length, &name, 0) < 0) {
                saved = errno ? errno : EILSEQ;
                free(name);
                break;
            }
            if (!strcmp(name, ".") || !strcmp(name, "..")) { free(name); goto next_entry; }
            if (ordinal == INT64_MAX) { free(name); saved = EOVERFLOW; break; }
            ordinal++;
            if (ordinal <= skip) { free(name); goto next_entry; }

            uint32_t type;
            int rc = nfsk_directory_entry_type(v->vol, ref, flags, &type);
            if (rc) { free(name); saved = -rc; break; }
            int stopped = cb(ctx, name, from_mft(MREF(ref)), type, ordinal);
            free(name);
            if (stopped) break;
        }
next_entry:
        /* Callbacks and name conversions may leave errno set on success. */
        errno = 0;
        entry = ntfs_index_next(entry, index);
        if (!entry && errno) saved = errno;
    }
out:
    if (index) {
        /* A failed walk can clear entry while still owning index buffers. */
        if (saved) index->bad_index = TRUE;
        ntfs_index_ctx_put(index);
    }
    if (nfsk_inode_close(dir) && !saved) saved = errno ? errno : EIO;
    return -saved;
}

/* ---- File I/O ---- */
int64_t nfsk_read(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || len < 0) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; nfsk_inode_close(ni); return -1; }

    int64_t result;
    s64 max = na->data_size;
    if (offset >= max) { result = 0; goto done; }
    if (offset + len > max) len = max - offset;

    int64_t total = 0;
    while (len > 0) {
        s64 r = ntfs_attr_pread(na, offset + total, len, (char *)buf + total);
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    result = total;
done:
    ntfs_attr_close(na);
    if (!v->read_only && result >= 0) ntfs_inode_update_times(ni, NTFS_UPDATE_ATIME);
    nfsk_inode_close(ni);
    return result;
}

int64_t nfsk_write(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, const void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || len < 0 || offset < 0 || len > INT64_MAX - offset || (len && !buf)) {
        if (out_errno) *out_errno = EINVAL;
        return -1;
    }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    /* 引擎按簇向上取整长度，预留取整空间以防有符号加法溢出。 */
    if (offset + len > INT64_MAX - (v->vol->cluster_size - 1)) {
        if (out_errno) *out_errno = EFBIG;
        return -1;
    }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; nfsk_inode_close(ni); return -1; }

    /* FSKit 可能把跨偏移写拆成乱序补零。仅跳过原 EOF 外或已映射空洞内的尾零；
     * 旧实体范围中的零覆盖仍完整写入。预分配区间不因此释放。 */
    int64_t requested = len;
    int64_t minimum = na->data_size > offset ? na->data_size - offset : 0;
    if (!(na->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED))) {
        if (minimum > 0 && NAttrNonResident(na) && ((const unsigned char *)buf)[len - 1] == 0) {
            s64 end = offset + len < na->data_size ? offset + len : na->data_size;
            runlist_element *run = ntfs_attr_find_vcn(na, (end - 1) >> v->vol->cluster_size_bits);
            if (run && run->lcn == LCN_HOLE && run->vcn >= 0 &&
                run->vcn <= (INT64_MAX >> v->vol->cluster_size_bits)) {
                s64 hole_start = run->vcn << v->vol->cluster_size_bits;
                minimum = hole_start > offset ? hole_start - offset : 0;
            }
        }
        while (len > minimum && ((const unsigned char *)buf)[len - 1] == 0) len--;
    }
    int64_t physical = len;
    int64_t total = 0;
    while (len > 0) {
        s64 r = ntfs_attr_pwrite(na, offset + total, len, (const char *)buf + total);
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    if (total == physical && physical < requested) {
        if (offset + requested > na->data_size && ntfs_attr_truncate(na, offset + requested)) {
            if (out_errno) *out_errno = errno ? errno : EIO;
            if (!total) total = -1;
        } else {
            total = requested;
        }
    }
    ntfs_attr_close(na);
    if (total > 0) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    if (nfsk_inode_close(ni) && total >= 0) {
        if (out_errno) *out_errno = errno ? errno : EIO;
        return -1;
    }
    return total;
}

/* ---- Extended attributes: named $DATA, never the unnamed file contents ---- */
static int xattr_name_error(const char *name) {
    if (!name || !*name) return EINVAL;
    if (strlen(name) > NFSK_MAX_XATTR_NAME) return ENAMETOOLONG;
    /* Do not expose NTFS/ntfs-3g private streams through a user xattr API. */
    if (name[0] == '$' || !strncmp(name, "ntfs-3g.", 8)) return EPERM;
    /* Windows uses this ADS as WOF file contents, rather than user metadata. */
    if (!strcasecmp(name, "WofCompressedData")) return EPERM;
    return 0;
}

static int xattr_unicode_name(const char *name, ntfschar **unicode) {
    int error = xattr_name_error(name);
    if (error) return -error;
    /* Attribute names are byte-sensitive, unlike normalized file names. Avoid
     * changing ntfs-3g's process-global filename normalization setting. */
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!string) return -EILSEQ;
    CFIndex length = CFStringGetLength(string), bytes = 0;
    *unicode = calloc((size_t)length + 1, sizeof(ntfschar));
    if (!*unicode) { CFRelease(string); return -ENOMEM; }
    CFIndex converted = CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF16LE,
                                        0, false, (UInt8 *)*unicode, length * 2, &bytes);
    CFRelease(string);
    return converted == length && bytes == length * 2 ? (int)length : -EILSEQ;
}

static int xattr_utf8_name(const ntfschar *unicode, int length, char *name) {
    CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)unicode,
                                                length * 2, kCFStringEncodingUTF16LE, false);
    if (!string) return -EILSEQ;
    CFIndex bytes = 0;
    CFIndex converted = CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)),
                                        kCFStringEncodingUTF8, 0, false, (UInt8 *)name,
                                        NFSK_MAX_XATTR_NAME, &bytes);
    CFIndex characters = CFStringGetLength(string);
    CFRelease(string);
    if (converted != characters) return -ENAMETOOLONG;
    name[bytes] = 0;
    return (size_t)bytes == strlen(name) ? (int)bytes : -EINVAL;
}

static int xattr_read_value(ntfs_attr *attr, void *buf, size_t size) {
    size_t done = 0;
    while (done < size) {
        s64 count = ntfs_attr_pread(attr, done, size - done, (char *)buf + done);
        if (count <= 0) return -(count < 0 && errno ? errno : EIO);
        done += (size_t)count;
    }
    return 0;
}

static int xattr_write_value(ntfs_attr *attr, const void *buf, size_t size) {
    size_t done = 0;
    /* Keep the old tail until all new bytes have been written. */
    while (done < size) {
        s64 count = ntfs_attr_pwrite(attr, done, size - done, (const char *)buf + done);
        if (count <= 0) return -(count < 0 && errno ? errno : EIO);
        done += (size_t)count;
    }
    if (ntfs_attr_pclose(attr) || ntfs_attr_truncate(attr, (s64)size)) return -(errno ? errno : EIO);
    return 0;
}

int64_t nfsk_getxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name, void *buf, size_t size) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfschar *unicode = NULL;
    int length = xattr_unicode_name(name, &unicode);
    if (length < 0) { free(unicode); return length; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { int error = errno ? errno : EIO; free(unicode); return -error; }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int64_t result;
    if (!attr) {
        result = -(errno == ENOENT ? ENOATTR : (errno ? errno : EIO));
    } else if (attr->data_size < 0) {
        result = -EIO;
    } else if (attr->data_size > NFSK_MAX_XATTR_SIZE) {
        result = -E2BIG;
    } else {
        result = attr->data_size;
        if (buf) {
            if (size < (size_t)result) result = -ERANGE;
            else {
                int rc = xattr_read_value(attr, buf, (size_t)result);
                if (rc) result = rc;
            }
        }
    }
    if (attr) ntfs_attr_close(attr);
    free(unicode);
    if (nfsk_inode_close(ni) && result >= 0) result = -(errno ? errno : EIO);
    return result;
}

int64_t nfsk_listxattr(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t size) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    int saved = search ? 0 : (errno ? errno : EIO);
    size_t total = 0;
    if (search) {
        while (true) {
            errno = 0;
            if (ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
                if (errno != ENOENT) saved = errno ? errno : EIO;
                break;
            }
            if (!search->attr->name_length) continue;
            char name[NFSK_MAX_XATTR_NAME + 1];
            int length = xattr_utf8_name((ntfschar *)((char *)search->attr + le16_to_cpu(search->attr->name_offset)),
                                         search->attr->name_length, name);
            if (length == -ENAMETOOLONG || length == -EINVAL) continue;
            if (length < 0) { saved = -length; break; }
            if (xattr_name_error(name)) continue;
            size_t bytes = (size_t)length + 1;
            if (total > NFSK_MAX_XATTR_SIZE - bytes) saved = E2BIG;
            else if (buf && (total > size || bytes > size - total)) saved = ERANGE;
            else {
                if (buf) memcpy(buf + total, name, bytes);
                total += bytes;
            }
            if (saved) break;
        }
        ntfs_attr_put_search_ctx(search);
    }
    if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    return saved ? -saved : (int64_t)total;
}

int nfsk_setxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name,
                  const void *value, size_t size, int policy) {
    if (!v || !v->vol || policy < NFSK_XATTR_SET || policy > NFSK_XATTR_DELETE ||
        (size && !value) || (policy == NFSK_XATTR_DELETE && (value || size))) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    if (size > NFSK_MAX_XATTR_SIZE) return -E2BIG;
    ntfschar *unicode = NULL;
    int length = xattr_unicode_name(name, &unicode);
    if (length < 0) { free(unicode); return length; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { int error = errno ? errno : EIO; free(unicode); return -error; }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int saved = 0;
    void *previous = NULL;
    size_t previous_size = 0;
    bool created = false;
    if (!attr && errno != ENOENT) { saved = errno ? errno : EIO; goto done; }
    if (attr && policy == NFSK_XATTR_CREATE) { saved = EEXIST; goto done; }
    if (!attr && (policy == NFSK_XATTR_REPLACE || policy == NFSK_XATTR_DELETE)) {
        saved = ENOATTR; goto done;
    }
    if (policy == NFSK_XATTR_DELETE) {
        if (ntfs_attr_rm(attr)) saved = errno ? errno : EIO;
        goto changed;
    }
    if (attr) {
        if (attr->data_size < 0) { saved = EIO; goto done; }
        if (attr->data_size > NFSK_MAX_XATTR_SIZE) { saved = E2BIG; goto done; }
        previous_size = (size_t)attr->data_size;
        if (previous_size) {
            previous = malloc(previous_size);
            if (!previous) { saved = ENOMEM; goto done; }
            int rc = xattr_read_value(attr, previous, previous_size);
            if (rc) { saved = -rc; goto done; }
        }
    } else {
        if (ntfs_attr_add(ni, AT_DATA, unicode, length, NULL, 0)) { saved = errno ? errno : EIO; goto done; }
        created = true;
        attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
        if (!attr) {
            saved = errno ? errno : EIO;
            if (ntfs_attr_remove(ni, AT_DATA, unicode, length))
                v->devctx->fatal_writeback_error = v->devctx->writeback_error = errno ? errno : EIO;
            goto done;
        }
    }
    saved = -xattr_write_value(attr, value, size);
    if (saved) {
        /* A failed replacement must not silently discard the old metadata. */
        int rollback = created ? ntfs_attr_rm(attr) : xattr_write_value(attr, previous, previous_size);
        if (rollback) v->devctx->fatal_writeback_error = v->devctx->writeback_error = EIO;
        goto done;
    }
changed:
    if (!saved) {
        if (!(ni->flags & FILE_ATTR_ARCHIVE)) { ni->flags |= FILE_ATTR_ARCHIVE; NInoFileNameSetDirty(ni); }
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    }
done:
    if (attr) ntfs_attr_close(attr);
    free(previous);
    free(unicode);
    if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    return -saved;
}

/* ---- Namespace mutation ---- */
uint64_t nfsk_create(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, uint32_t type, int *out_errno) {
    if (!v || !v->vol) { if (out_errno) *out_errno = EINVAL; return 0; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return 0; }
    if (type != NFSK_TYPE_DIR && type != NFSK_TYPE_FILE) { if (out_errno) *out_errno = ENOTSUP; return 0; }
    if (is_reserved_mft(to_mref(dir_ino))) { if (out_errno) *out_errno = EPERM; return 0; }
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }
    if (nfsk_unlinked_directory(dir)) {
        nfsk_inode_close(dir); if (out_errno) *out_errno = ENOENT; return 0;
    }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; nfsk_inode_close(dir); return 0; }

    errno = 0;
    u64 existing = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (existing != (u64)-1 || errno != ENOENT) {
        int saved = existing != (u64)-1 ? EEXIST : (errno ? errno : EIO);
        free(uname); nfsk_inode_close(dir);
        if (out_errno) *out_errno = saved;
        return 0;
    }
    nfsk_inode_ref *owned = calloc(1, sizeof(*owned));
    if (!owned) { free(uname); nfsk_inode_close(dir); if (out_errno) *out_errno = ENOMEM; return 0; }
    mode_t kind = (type == NFSK_TYPE_DIR) ? S_IFDIR : S_IFREG;
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, ulen, kind);
    free(uname);
    if (!ni) { if (out_errno) *out_errno = errno ? errno : EIO; free(owned); nfsk_inode_close(dir); return 0; }
    owned->inode = ni; owned->next = v->devctx->inodes; v->devctx->inodes = owned;
    uint64_t new_ino = from_mft(ni->mft_no);
    nfsk_inode_close(ni);
    nfsk_inode_close(dir);
    if (v->devctx->writeback_error) { if (out_errno) *out_errno = v->devctx->writeback_error; return 0; }
    return new_ino;
}

int nfsk_remove(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8) {
    if (!v || !v->vol || !name_utf8) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(dir_ino))) return -EPERM;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { int e = errno; nfsk_inode_close(dir); return -e; }
    if (nfsk_is_retention_name(v->vol, dir->mft_no, uname, ulen)) {
        free(uname); nfsk_inode_close(dir); return -ENOENT;
    }

    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref == (u64)-1) { int e = errno ? errno : ENOENT; free(uname); nfsk_inode_close(dir); return -e; }
    if (is_reserved_mft(MREF(mref))) { free(uname); nfsk_inode_close(dir); return -EPERM; }  /* don't remove metadata */
    ntfs_inode *ni = nfsk_inode_open(v->vol, mref);
    if (!ni) { int e = errno; free(uname); nfsk_inode_close(dir); return -e; }
    int rc = nfsk_delete(v->vol, ni, dir, uname, ulen);
    int e = rc ? (errno ? errno : EIO) : 0;
    free(uname);
    return rc ? -e : 0;
}

int nfsk_truncate(ntfs_fskit_volume *v, uint64_t ino, uint64_t size) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (size > INT64_MAX) return -EFBIG;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    if (nfsk_inode_type(ni) != NFSK_TYPE_FILE) {
        int error = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? EISDIR : ENOTSUP;
        nfsk_inode_close(ni);
        return -error;
    }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int e = errno; nfsk_inode_close(ni); return -e; }
    int rc = ntfs_attr_truncate(na, (s64)size);
    int e = rc ? (errno ? errno : EIO) : 0;
    ntfs_attr_close(na);
    if (!rc) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    if (nfsk_inode_close(ni) && !e) e = errno ? errno : EIO;
    return e ? -e : 0;
}

int nfsk_set_times(ntfs_fskit_volume *v, uint64_t ino,
                   int64_t mtime_sec, int64_t mtime_nsec, int64_t atime_sec, int64_t atime_nsec) {
    nfsk_metadata_t metadata = {0};
    if (mtime_sec != INT64_MIN) metadata.valid |= NFSK_SET_MTIME;
    if (atime_sec != INT64_MIN) metadata.valid |= NFSK_SET_ATIME;
    metadata.mtime_sec = mtime_sec; metadata.mtime_nsec = mtime_nsec;
    metadata.atime_sec = atime_sec; metadata.atime_nsec = atime_nsec;
    return nfsk_set_metadata(v, ino, &metadata);
}

static bool nfsk_valid_time(int64_t sec, int64_t nsec) {
    __int128 ticks = ((__int128)sec + 11644473600LL) * 10000000 + nsec / 100;
    return nsec >= 0 && nsec < 1000000000 && ticks >= 0 && ticks <= INT64_MAX;
}

int nfsk_validate_metadata(const nfsk_metadata_t *m) {
    if (!m || (m->valid & ~(NFSK_SET_MTIME | NFSK_SET_ATIME | NFSK_SET_BTIME | NFSK_SET_FLAGS))) return -EINVAL;
    if (((m->valid & NFSK_SET_MTIME) && !nfsk_valid_time(m->mtime_sec, m->mtime_nsec)) ||
        ((m->valid & NFSK_SET_ATIME) && !nfsk_valid_time(m->atime_sec, m->atime_nsec)) ||
        ((m->valid & NFSK_SET_BTIME) && !nfsk_valid_time(m->btime_sec, m->btime_nsec))) return -EINVAL;
    if ((m->valid & NFSK_SET_FLAGS) && (m->flags & ~UF_HIDDEN)) return -ENOTSUP;
    return 0;
}

int nfsk_set_metadata(ntfs_fskit_volume *v, uint64_t ino, const nfsk_metadata_t *m) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    int valid = nfsk_validate_metadata(m);
    if (valid) return valid;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    uint32_t fields = m->valid;
    if (to_mref(ino) == FILE_root && (fields & NFSK_SET_FLAGS)) {
        /* The root is always visible in macOS. Clearing its exposed flags is
         * a no-op; retain the original NTFS flags for other operating systems.
         * Resolve flag-only requests before opening an inode for writeback. */
        if (m->flags & UF_HIDDEN) return -ENOTSUP;
        fields &= ~NFSK_SET_FLAGS;
        if (!fields) return 0;
    }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    /* HIDDEN distinguishes some Interix special files from ordinary data. */
    if ((fields & NFSK_SET_FLAGS) &&
        (!!(m->flags & UF_HIDDEN) != !!(ni->flags & FILE_ATTR_HIDDEN)) &&
        !(ni->flags & FILE_ATTR_REPARSE_POINT) &&
        (ni->flags & FILE_ATTR_SYSTEM) && ntfs_interix_types(ni) != NTFS_DT_REG) {
        nfsk_inode_close(ni);
        return -ENOTSUP;
    }
    if (fields & NFSK_SET_MTIME) { struct timespec ts = { (time_t)m->mtime_sec, (long)m->mtime_nsec }; ni->last_data_change_time = timespec2ntfs(ts); }
    if (fields & NFSK_SET_ATIME) { struct timespec ts = { (time_t)m->atime_sec, (long)m->atime_nsec }; ni->last_access_time = timespec2ntfs(ts); }
    if (fields & NFSK_SET_BTIME) { struct timespec ts = { (time_t)m->btime_sec, (long)m->btime_nsec }; ni->creation_time = timespec2ntfs(ts); }
    if (fields & NFSK_SET_FLAGS) {
        if (m->flags & UF_HIDDEN) ni->flags |= FILE_ATTR_HIDDEN;
        else ni->flags &= ~FILE_ATTR_HIDDEN;
    }
    ni->last_mft_change_time = ntfs_current_time();
    ntfs_inode_mark_dirty(ni);
    NInoFileNameSetDirty(ni);
    int rc = nfsk_inode_close(ni);
    return rc ? -errno : 0;
}

/*
 * Rename helpers. libntfs has no path-based front-end (that lives in ntfs-3g's
 * FUSE layer, which we don't link), so these mirror src/ntfs-3g.c's rename logic
 * on top of the inode primitives. Each is self-contained — it re-opens its
 * directory by inode number — because ntfs_delete() closes BOTH the target inode
 * and its directory inode (libntfs-3g/dir.c, out:), while ntfs_link() closes neither.
 */

/* Add directory entry `name` in directory #dir_no pointing at inode `ref`. */
static int nfsk_link_name(ntfs_volume *vol, uint64_t dir_no, u64 ref,
                          const ntfschar *name, int name_len) {
    ntfs_inode *dir = nfsk_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    if (nfsk_unlinked_directory(dir)) { nfsk_inode_close(dir); errno = ENOENT; return -1; }
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) { int e = errno; nfsk_inode_close(dir); errno = e; return -1; }
    errno = 0;
    u64 existing = ntfs_inode_lookup_by_name(dir, name, name_len);
    if (existing != (u64)-1 || errno != ENOENT) {
        int e = existing != (u64)-1 ? EEXIST : (errno ? errno : EIO);
        nfsk_inode_close(ni); nfsk_inode_close(dir); errno = e; return -1;
    }
    int r = ntfs_link(ni, dir, name, name_len);   /* closes neither inode */
    int e = errno;
    nfsk_inode_close(ni);
    nfsk_inode_close(dir);
    if (r) { errno = e; return -1; }
    return 0;
}

/* Remove directory entry `name` from directory #dir_no. */
static int nfsk_unlink_name(ntfs_volume *vol, uint64_t dir_no,
                            const ntfschar *name, int name_len) {
    ntfs_inode *dir = nfsk_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    u64 ref = ntfs_inode_lookup_by_name(dir, name, name_len);
    if (ref == (u64)-1) { int e = errno; nfsk_inode_close(dir); errno = e ? e : ENOENT; return -1; }
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) { int e = errno; nfsk_inode_close(dir); errno = e; return -1; }
    /* ntfs_delete closes BOTH ni and dir, even on failure. */
    return nfsk_delete(vol, ni, dir, name, name_len) ? -1 : 0;
}

int nfsk_open_item(ntfs_fskit_volume *v, uint64_t ino) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    nfsk_open_ref *existing = nfsk_open_ref_for(v->vol, to_mref(ino));
    if (existing) { existing->open = true; return 0; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    if (nfsk_inode_close(ni)) return -(errno ? errno : EIO);
    nfsk_open_ref *entry = calloc(1, sizeof(*entry));
    if (!entry) return -ENOMEM;
    entry->ref = to_mref(ino);
    entry->open = true;
    entry->next = v->devctx->open_items;
    v->devctx->open_items = entry;
    return 0;
}

static int nfsk_release_open_ref(ntfs_fskit_volume *v, nfsk_open_ref **slot) {
    nfsk_open_ref *entry = *slot;
    entry->open = false;
    if (entry->anchor && nfsk_unlink_name(v->vol, NFSK_ROOT_INO, entry->anchor, entry->anchor_length)) {
        if (errno != ENOENT) return -(errno ? errno : EIO);
    }
    *slot = entry->next;
    free(entry->anchor);
    free(entry);
    return 0;
}

int nfsk_close_item(ntfs_fskit_volume *v, uint64_t ino) {
    if (!v || !v->vol) return -EINVAL;
    nfsk_open_ref **slot = &v->devctx->open_items;
    while (*slot && MREF((*slot)->ref) != to_mref(ino)) slot = &(*slot)->next;
    return *slot ? nfsk_release_open_ref(v, slot) : 0;
}

/* Unique temp-name disambiguator; all bridge calls run under the volume lock. */
static unsigned nfsk_rename_seq = 0;

/*
 * Replace an existing, different destination, mirroring
 * src/ntfs-3g.c:ntfs_fuse_safe_rename(). The destination is first backed up under a
 * temp name, the source is moved into place, and only then is the backup dropped —
 * with the destination restored on any failure. So a failed link never destroys the
 * destination's data (the flaw in the previous delete-first implementation). A
 * non-empty-directory destination fails cleanly at step (2): ntfs_delete refuses it.
 */
static int nfsk_safe_overwrite(ntfs_volume *vol,
                               uint64_t src_dir, const ntfschar *usrc, int slen, u64 sref,
                               uint64_t dst_dir, const ntfschar *udst, int dlen, u64 dref) {
    ntfschar *utmp = NULL;
    int tmplen = 0, e;
    /* Pick a temp name that does not already exist in the destination directory. */
    {
        ntfs_inode *ddir = nfsk_inode_open(vol, to_mref(dst_dir));
        if (!ddir) return -1;
        int found = 0;
        for (int tries = 0; tries < 4096; tries++) {
            char tmpname[64];
            snprintf(tmpname, sizeof(tmpname), "ntfs3g-rn-%016llx-%u",
                     (unsigned long long)MREF(dref), ++nfsk_rename_seq);
            free(utmp); utmp = NULL;
            tmplen = ntfs_mbstoucs(tmpname, &utmp);
            if (tmplen < 0) { nfsk_inode_close(ddir); free(utmp); return -1; }
            errno = 0;
            u64 ex = ntfs_inode_lookup_by_name(ddir, utmp, tmplen);
            if (ex == (u64)-1) {
                if (errno == 0 || errno == ENOENT) { found = 1; break; }   /* name is free */
                int le = errno; nfsk_inode_close(ddir); free(utmp); errno = le; return -1;
            }
        }
        nfsk_inode_close(ddir);
        if (!found) { free(utmp); errno = EEXIST; return -1; }
    }

    /* (1) back up the destination under the temp name */
    if (nfsk_link_name(vol, dst_dir, dref, utmp, tmplen)) {
        e = errno; free(utmp); errno = e; return -1;
    }
    /* (2) remove the destination's original name */
    if (nfsk_unlink_name(vol, dst_dir, udst, dlen)) {
        e = errno;                                    /* dst keeps its name */
        nfsk_unlink_name(vol, dst_dir, utmp, tmplen); /* drop the backup */
        free(utmp); errno = e; return -1;
    }
    /* (3) give the source the destination's name */
    if (nfsk_link_name(vol, dst_dir, sref, udst, dlen)) {
        e = errno;
        if (nfsk_link_name(vol, dst_dir, dref, udst, dlen) == 0)  /* restore dst */
            nfsk_unlink_name(vol, dst_dir, utmp, tmplen);
        free(utmp); errno = e; return -1;
    }
    /* (4) drop the source's old name */
    if (nfsk_unlink_name(vol, src_dir, usrc, slen)) {
        e = errno;
        if (nfsk_unlink_name(vol, dst_dir, udst, dlen) == 0) {        /* undo (3) */
            if (nfsk_link_name(vol, dst_dir, dref, udst, dlen) == 0)  /* restore dst */
                nfsk_unlink_name(vol, dst_dir, utmp, tmplen);
        }
        free(utmp); errno = e; return -1;
    }
    /* success: the source holds the destination name; dropping the backup frees the
       destination's data (its last reference). The rename has already succeeded, so a
       cleanup failure is logged (leaving an orphan temp link) rather than reported as
       a rename error. */
    if (nfsk_unlink_name(vol, dst_dir, utmp, tmplen) != 0)
        ntfs_log_error("xntfs: rename left an orphan temp backup link (errno %d)\n", errno);
    free(utmp);
    return 0;
}

/*
 * Rename src_dir/src_name -> dst_dir/dst_name, mirroring src/ntfs-3g.c's
 * ntfs_fuse_rename(): a rename whose destination resolves to the same inode (a
 * case-only change, or another hard-link name) is a no-op; an existing, different
 * destination is replaced recoverably; otherwise the new name is linked before the
 * old name is unlinked, so the source is never lost if the unlink fails.
 */
int nfsk_rename(ntfs_fskit_volume *v, uint64_t src_dir, const char *src_name,
                uint64_t dst_dir, const char *dst_name) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (!src_name || !dst_name) return -EINVAL;

    ntfs_volume *vol = v->vol;
    if (is_reserved_mft(to_mref(src_dir)) || is_reserved_mft(to_mref(dst_dir))) return -EPERM;
    ntfschar *usrc = NULL, *udst = NULL;
    int slen, dlen, rc = 0, e = 0, src_isdir = 0;
    u64 sref = (u64)-1, dref = (u64)-1;

    slen = ntfs_mbstoucs(src_name, &usrc);
    if (slen < 0) { e = errno; rc = -1; goto out; }
    dlen = ntfs_mbstoucs(dst_name, &udst);
    if (dlen < 0) { e = errno; rc = -1; goto out; }
    if (nfsk_is_retention_name(vol, to_mref(src_dir), usrc, slen) ||
        nfsk_is_retention_name(vol, to_mref(dst_dir), udst, dlen)) {
        e = ENOENT; rc = -1; goto out;
    }

    /* Resolve the source inode. */
    {
        ntfs_inode *sdir = nfsk_inode_open(vol, to_mref(src_dir));
        if (!sdir) { e = errno; rc = -1; goto out; }
        sref = ntfs_inode_lookup_by_name(sdir, usrc, slen);
        e = errno;
        nfsk_inode_close(sdir);
        if (sref == (u64)-1) { e = e ? e : ENOENT; rc = -1; goto out; }
    }
    if (is_reserved_mft(MREF(sref))) { e = EPERM; rc = -1; goto out; }  /* can't move metadata */

    src_isdir = nfsk_isdir(vol, sref, NULL);
    if (src_isdir < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
    /* Moving a directory into its own subtree would create a cycle (mv A A/B/C). */
    if (src_isdir && src_dir != dst_dir) {
        int desc = nfsk_dir_contains(vol, sref, dst_dir);
        if (desc < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
        if (desc)     { e = EINVAL; rc = -1; goto out; }
    }

    /* Resolve the destination inode (may be absent). A -1 result means "not found"
       only when errno is ENOENT/unset; any other errno is a real error (corruption or
       I/O) and must abort rather than fall through to the "no destination" path. */
    {
        ntfs_inode *ddir = nfsk_inode_open(vol, to_mref(dst_dir));
        if (!ddir) { e = errno; rc = -1; goto out; }
        errno = 0;
        dref = ntfs_inode_lookup_by_name(ddir, udst, dlen);
        int le = errno;
        nfsk_inode_close(ddir);
        if (dref == (u64)-1 && le != 0 && le != ENOENT) { e = le; rc = -1; goto out; }
    }

    if (dref != (u64)-1) {
        /* Same underlying file (case-only rename, or another hard-link name): a
           no-op, exactly as upstream ntfs_fuse_rename treats it. The on-disk name
           keeps its existing case. */
        if (MREF(dref) == MREF(sref)) { rc = 0; goto out; }
        if (is_reserved_mft(MREF(dref))) { e = EPERM; rc = -1; goto out; }  /* don't clobber metadata */
        /* POSIX type compatibility + empty-target checks, before any mutation. */
        int dst_empty = 0;
        int dst_isdir = nfsk_isdir(vol, dref, &dst_empty);
        if (dst_isdir < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
        if (dst_isdir && !src_isdir)  { e = EISDIR;    rc = -1; goto out; }  /* file over dir      */
        if (!dst_isdir && src_isdir)  { e = ENOTDIR;   rc = -1; goto out; }  /* dir over non-dir   */
        if (dst_isdir && !dst_empty)  { e = ENOTEMPTY; rc = -1; goto out; }  /* over non-empty dir */
        /* Replace an existing, different destination — recoverable. */
        if (nfsk_safe_overwrite(vol, src_dir, usrc, slen, sref,
                                dst_dir, udst, dlen, dref)) { e = errno; rc = -1; }
        goto out;
    }

    /* No existing destination: link the new name, then unlink the old; if the
       unlink fails, undo the new link. The new name is always created before the
       old is removed, so the source is never lost. */
    if (nfsk_link_name(vol, dst_dir, sref, udst, dlen)) { e = errno; rc = -1; goto out; }
    if (nfsk_unlink_name(vol, src_dir, usrc, slen)) {
        e = errno; rc = -1;
        nfsk_unlink_name(vol, dst_dir, udst, dlen);   /* undo the new link */
    }

out:
    free(usrc); free(udst);
    if (!rc && v->devctx->writeback_error) return -v->devctx->writeback_error;
    return rc ? -e : 0;
}

/* Hard link: add `name` in dir_ino as another name for inode `target_ino`. NTFS keeps
 * a link count + multiple FILE_NAME attributes, so this is a thin wrapper over ntfs_link
 * (the bridge is inode-keyed — no path map to update). Directories can't be hard-linked. */
int nfsk_link(ntfs_fskit_volume *v, uint64_t target_ino, uint64_t dir_ino,
              const char *name_utf8, int *out_errno) {
    if (!v || !v->vol || !name_utf8) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(target_ino)) || is_reserved_mft(to_mref(dir_ino))) {
        if (out_errno) *out_errno = EPERM; return -1;
    }
    int isdir = nfsk_isdir(v->vol, to_mref(target_ino), NULL);
    if (isdir < 0) { if (out_errno) *out_errno = errno ? errno : EIO; return -1; }
    /* FSKit expects ENOTSUP when hard links aren't supported for the object's type (a dir). */
    if (isdir)     { if (out_errno) *out_errno = ENOTSUP; return -1; }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; return -1; }
    int r = nfsk_link_name(v->vol, dir_ino, to_mref(target_ino), uname, ulen);
    int e = errno;
    free(uname);
    if (!r && v->devctx->writeback_error) { r = -1; e = v->devctx->writeback_error; }
    if (r) { if (out_errno) *out_errno = e ? e : EIO; return -1; }
    return 0;
}

uint64_t nfsk_symlink(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name,
                      const char *target, int *out_errno) {
    int error = 0;
    uint64_t ino = 0;
    ntfschar *unicode = NULL, *link = NULL;
    ntfs_inode *dir = NULL;
    nfsk_inode_ref *owned = NULL;
    if (!v || !v->vol || !name || !target || !*target || !*name ||
        strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) { error = EINVAL; goto done; }
    if (v->read_only) { error = EROFS; goto done; }
    if (is_reserved_mft(to_mref(dir_ino))) { error = EPERM; goto done; }
    if (strlen(target) >= 4096) { error = ENAMETOOLONG; goto done; }
    int length = ntfs_mbstoucs(name, &unicode);
    int link_length = ntfs_mbstoucs(target, &link);
    if (length < 0 || link_length < 0) { error = errno ? errno : EILSEQ; goto done; }
    if (length > 255 || link_length > 4096) { error = ENAMETOOLONG; goto done; }
    dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { error = errno ? errno : EIO; goto done; }
    if (nfsk_unlinked_directory(dir)) { error = ENOENT; goto done; }
    errno = 0;
    MFT_REF existing = ntfs_inode_lookup_by_name(dir, unicode, length);
    if (existing != (MFT_REF)-1 || errno != ENOENT) {
        error = existing != (MFT_REF)-1 ? EEXIST : (errno ? errno : EIO);
        goto done;
    }
    owned = calloc(1, sizeof(*owned));
    if (!owned) { error = ENOMEM; goto done; }
    int previous_format = v->vol->special_files;
    v->vol->special_files = NTFS_FILES_WSL;
    ntfs_inode *ni = ntfs_create_symlink(dir, const_cpu_to_le32(0), unicode, length, link, link_length);
    v->vol->special_files = previous_format;
    if (!ni) { error = errno ? errno : EIO; goto done; }
    owned->inode = ni; owned->next = v->devctx->inodes; v->devctx->inodes = owned;
    owned = NULL;
    ino = from_mft(ni->mft_no);
    /* A resident directory index is still in dir->mrec. Publish it before
     * syncing the symlink's FILE_NAME through a freshly opened parent. */
    if (nfsk_inode_close(dir)) error = errno ? errno : EIO;
    dir = NULL;
    if (!error && nfsk_inode_close(ni)) error = errno ? errno : EIO;
done:
    if (dir && nfsk_inode_close(dir) && !error) error = errno ? errno : EIO;
    free(owned); free(unicode); free(link);
    if (out_errno) *out_errno = error;
    return error ? 0 : ino;
}

int nfsk_rename_volume(ntfs_fskit_volume *v, const char *name) {
    if (!v || !v->vol || !name || !*name) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (v->devctx->writeback_error) return -v->devctx->writeback_error;
    if (strpbrk(name, "\\/:*?\"<>|")) return -EINVAL;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++)
        if (*p < 32) return -EINVAL;
    ntfschar *unicode = NULL;
    int length = ntfs_mbstoucs(name, &unicode);
    if (length < 0) return -(errno ? errno : EILSEQ);
    int error = length >= 128 ? ENAMETOOLONG : 0;
    /* AT_VOLUME_NAME contains exactly the label's UTF-16 code units, without NUL. */
    if (!error && ntfs_volume_rename(v->vol, unicode, length)) error = errno ? errno : EIO;
    free(unicode);
    if (!error) return nfsk_sync(v);
    return -error;
}

/* ntfsfallocate uses the same public attribute APIs to preserve logical EOF
 * after allocating clusters. Do not expose the uninitialized reserved tail. */
static int nfsk_restore_data_size(ntfs_attr *data, ntfs_attr_search_ctx *search, s64 size, s64 initialized) {
    ntfs_attr_reinit_search_ctx(search);
    int error = 0;
    if (ntfs_attr_lookup(AT_DATA, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) error = errno ? errno : EIO;
    else if (!search->attr->non_resident) {
        if (data->data_size != size) error = EIO;
    } else {
        data->data_size = size;
        data->initialized_size = initialized;
        search->attr->data_size = cpu_to_sle64(size);
        search->attr->initialized_size = cpu_to_sle64(initialized);
        data->ni->data_size = size;
        data->ni->allocated_size = data->allocated_size;
        ntfs_inode_mark_dirty(search->ntfs_ino);
        NInoFileNameSetDirty(data->ni);
    }
    return -error;
}

int64_t nfsk_preallocate(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                         int64_t length, bool from_eof) {
    if (!v || !v->vol || length < 0 || (!from_eof && offset < 0)) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr *data = NULL;
    ntfs_attr_search_ctx *search = NULL;
    int64_t result = 0;
    uint32_t type = nfsk_inode_type(ni);
    if (type != NFSK_TYPE_FILE) { result = type == NFSK_TYPE_DIR ? -EISDIR : -ENOTSUP; goto done; }
    data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) { result = -(errno ? errno : EIO); goto done; }
    if (data->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED | ATTR_IS_SPARSE)) {
        result = -ENOTSUP; goto done;
    }
    if (!length) goto done;
    s64 previous = NAttrNonResident(data) ? data->allocated_size : 0;
    s64 size = data->data_size, initialized = data->initialized_size;
    s64 start = from_eof ? previous : offset;
    s64 mask = v->vol->cluster_size - 1;
    if (start > INT64_MAX - length || start + length > INT64_MAX - mask) { result = -EFBIG; goto done; }
    s64 target = (start + length + mask) & ~mask;
    if (target <= previous) goto done;
    if (((target - previous) >> v->vol->cluster_size_bits) > v->vol->free_clusters) {
        result = -ENOSPC; goto done;
    }
    search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) { result = -(errno ? errno : ENOMEM); goto done; }
    if (ntfs_attr_truncate_solid(data, target)) result = -(errno ? errno : EIO);
    int restore = nfsk_restore_data_size(data, search, size, initialized);
    if (restore) {
        v->devctx->fatal_writeback_error = v->devctx->writeback_error = -restore;
        result = restore;
    }
    if (!result) {
        result = data->allocated_size - previous;
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    }
done:
    if (search) ntfs_attr_put_search_ctx(search);
    if (data) ntfs_attr_close(data);
    if (nfsk_inode_close(ni) && result >= 0) result = -(errno ? errno : EIO);
    return result;
}

int nfsk_seek_region(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                     bool seek_data, int64_t *result) {
    if (!v || !v->vol || !result || offset < 0) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr *data = NULL;
    int error = 0;
    uint32_t type = nfsk_inode_type(ni);
    if (type != NFSK_TYPE_FILE) { error = type == NFSK_TYPE_DIR ? EISDIR : ENOTSUP; goto done; }
    data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) { error = errno ? errno : EIO; goto done; }
    if (offset >= data->data_size) { error = ENXIO; goto done; }
    if (!NAttrNonResident(data) || (data->data_flags & ATTR_COMPRESSION_MASK)) {
        *result = seek_data ? offset : data->data_size;
        goto done;
    }
    if (ntfs_attr_map_whole_runlist(data)) { error = errno ? errno : EIO; goto done; }
    if (!data->rl) { error = EIO; goto done; }
    *result = seek_data ? -1 : data->data_size;
    for (runlist_element *run = data->rl; run && run->length; run++) {
        if (run->vcn < 0 || run->length < 0 || run->lcn < LCN_HOLE ||
            run->vcn > (INT64_MAX >> v->vol->cluster_size_bits) - run->length) {
            error = EIO; break;
        }
        int64_t start = run->vcn << v->vol->cluster_size_bits;
        int64_t end = (run->vcn + run->length) << v->vol->cluster_size_bits;
        if (end <= offset) continue;
        if (start >= data->data_size) break;
        if ((run->lcn != LCN_HOLE) == seek_data) {
            *result = start > offset ? start : offset;
            break;
        }
    }
    if (!error && *result < 0) error = ENXIO;
done:
    if (data) ntfs_attr_close(data);
    if (nfsk_inode_close(ni) && !error) error = errno ? errno : EIO;
    return -error;
}

int nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap) {
    if (!v || !v->vol || !buf || cap == 0) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EINVAL;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    /* "/" mount point: a Windows *absolute* target is rewritten relative to the mount
       root (best effort); relative targets — the common POSIX case — pass through as-is. */
    char *target = nfsk_symlink_target(ni);
    int saved = errno;
    nfsk_inode_close(ni);
    if (!target) return -(saved ? saved : EINVAL);
    size_t tlen = strlen(target);
    if (tlen >= cap) { free(target); return -ENAMETOOLONG; }   /* don't silently truncate the target */
    memcpy(buf, target, tlen + 1);
    free(target);
    return 0;
}
