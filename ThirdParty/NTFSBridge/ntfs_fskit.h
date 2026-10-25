/*
 * ntfs_fskit.h - Swift-facing C API bridging FSKit to libntfs-3g.
 *
 * Opaque, ObjC/Swift-friendly surface. No libntfs-3g types leak through, so the
 * Swift bridging header can import it without dragging in libntfs headers (whose
 * `enum BOOL` collides with ObjC's BOOL).
 *
 * Two translation units back this header:
 *   - ntfs_fskit.c        : libntfs-3g logic (pure C, no FSKit/ObjC).
 *   - ntfs_device_fskit.m : block I/O over FSBlockDeviceResource (ObjC).
 */

#ifndef NTFS_FSKIT_H
#define NTFS_FSKIT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Item types — values intentionally match FSKit's FSItemType enum. */
enum {
    NFSK_TYPE_UNKNOWN   = 0,
    NFSK_TYPE_FILE      = 1,
    NFSK_TYPE_DIR       = 2,
    NFSK_TYPE_SYMLINK   = 3,
    NFSK_TYPE_FIFO      = 4,
    NFSK_TYPE_CHARDEV   = 5,
    NFSK_TYPE_BLOCKDEV  = 6,
    NFSK_TYPE_SOCKET    = 7,
};

/* Inode reported for the root directory (matches FSItem.Identifier.rootDirectory). */
#define NFSK_ROOT_INO 2ULL
/* Parent reported for the root directory (matches FSItem.Identifier.parentOfRoot). */
#define NFSK_PARENT_OF_ROOT 1ULL

typedef struct ntfs_fskit_volume ntfs_fskit_volume;

typedef struct {
    uint32_t cluster_size;
    uint64_t total_clusters;
    uint64_t free_clusters;
    uint64_t total_files;
    uint64_t free_files;
    uint64_t volume_serial;      /* NTFS 64-bit boot-sector serial; 0 if unreadable */
    uint8_t  read_only;
    char     volume_name[1024];  /* UTF-8, NUL-terminated */
} nfsk_statfs_t;

typedef struct {
    uint64_t ino;
    uint64_t parent_ino;   /* parent dir in our numbering; 0 if unknown */
    uint32_t type;         /* NFSK_TYPE_* */
    uint32_t mode;         /* synthesized POSIX permission bits */
    uint32_t flags;        /* supported BSD flags, currently UF_HIDDEN */
    uint32_t nlink;
    uint64_t size;
    uint64_t alloc_size;
    int64_t  mtime_sec;  int64_t mtime_nsec;
    int64_t  atime_sec;  int64_t atime_nsec;
    int64_t  ctime_sec;  int64_t ctime_nsec;
    int64_t  btime_sec;  int64_t btime_nsec;
} nfsk_attr_t;

/* Directory enumeration callback. Return 0 to continue, non-zero to stop.
 * `cookie` is an opaque resume position for the *next* entry. */
typedef int (*nfsk_dir_cb)(void *ctx, const char *name_utf8,
                           uint64_t ino, uint32_t type, int64_t cookie);

/* --- lifecycle --- */
ntfs_fskit_volume *nfsk_mount(void *resource, bool read_only, int *out_errno);
int  nfsk_probe(void *resource, char *name_out, size_t name_cap, uint64_t *serial_out);
void nfsk_umount(ntfs_fskit_volume *v);
int  nfsk_sync(ntfs_fskit_volume *v);
int  nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out);

/* Read-only mount preflight, not a full consistency scan or repair. The resource
 * must not be mounted writable elsewhere. Returns 0 or -errno and a diagnostic. */
enum {
    NFSK_CHECK_CLEAN = 0,
    NFSK_CHECK_METADATA = 1,
    NFSK_CHECK_DIRTY = 2,
    NFSK_CHECK_HIBERNATED = 3,
    NFSK_CHECK_JOURNAL = 4,
};
int  nfsk_quick_check(void *resource, int *reason);

/* --- item operations --- */
int      nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out);
uint64_t nfsk_lookup(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, int *out_errno);
uint64_t nfsk_lookup_name(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                          char *canonical_name, size_t capacity, int *out_errno);
int      nfsk_readdir(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie, void *ctx, nfsk_dir_cb cb);
int64_t  nfsk_read(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, void *buf, int64_t len, int *out_errno);
int64_t  nfsk_write(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, const void *buf, int64_t len, int *out_errno);
uint64_t nfsk_create(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, uint32_t type, int *out_errno);
int      nfsk_link(ntfs_fskit_volume *v, uint64_t target_ino, uint64_t dir_ino, const char *name_utf8, int *out_errno);
int      nfsk_remove(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8);
int      nfsk_truncate(ntfs_fskit_volume *v, uint64_t ino, uint64_t size);
int      nfsk_set_times(ntfs_fskit_volume *v, uint64_t ino,
                        int64_t mtime_sec, int64_t mtime_nsec,
                        int64_t atime_sec, int64_t atime_nsec);
enum {
    NFSK_SET_MTIME = 1,
    NFSK_SET_ATIME = 2,
    NFSK_SET_BTIME = 4,
    NFSK_SET_FLAGS = 8,
};
typedef struct {
    uint32_t valid;
    uint32_t flags;
    int64_t mtime_sec, mtime_nsec;
    int64_t atime_sec, atime_nsec;
    int64_t btime_sec, btime_nsec;
} nfsk_metadata_t;
int      nfsk_validate_metadata(const nfsk_metadata_t *metadata);
int      nfsk_set_metadata(ntfs_fskit_volume *v, uint64_t ino, const nfsk_metadata_t *metadata);
uint64_t nfsk_symlink(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name,
                      const char *target, int *out_errno);
int      nfsk_rename_volume(ntfs_fskit_volume *v, const char *name);
int64_t  nfsk_preallocate(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                          int64_t length, bool from_eof);
int      nfsk_seek_region(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                          bool seek_data, int64_t *result);

/* FSKit open/close describe access modes, not descriptor counts. Opening is
 * idempotent; call close only when no access modes remain. */
int      nfsk_open_item(ntfs_fskit_volume *v, uint64_t ino);
int      nfsk_close_item(ntfs_fskit_volume *v, uint64_t ino);
int      nfsk_rename(ntfs_fskit_volume *v, uint64_t src_dir, const char *src_name,
                     uint64_t dst_dir, const char *dst_name);
int      nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap);

/* Native xattrs use same-named NTFS data streams (ntfs-3g openxattr mapping).
 * FSKit transfers whole values, so bound per-request memory consumption. */
enum {
    NFSK_MAX_XATTR_SIZE = 128 * 1024,
    NFSK_MAX_XATTR_NAME = 127,
    NFSK_XATTR_SET = 0,
    NFSK_XATTR_CREATE = 1,
    NFSK_XATTR_REPLACE = 2,
    NFSK_XATTR_DELETE = 3,
};
/* get/list return byte counts or -errno; NULL buffers query the required size.
 * list returns NUL-terminated names concatenated without an extra terminator. */
int64_t nfsk_getxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name, void *buf, size_t size);
int64_t nfsk_listxattr(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t size);
int     nfsk_setxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name,
                     const void *value, size_t size, int policy);

/* --- Backend (implemented in ntfs_device_fskit.m) ---
 * A backend wraps either an FSBlockDeviceResource (a real disk/partition) or an
 * opened image file, behind one I/O interface. Create one, pass the returned
 * opaque pointer to nfsk_mount / nfsk_probe (as the `resource` argument), and
 * release it with nfsk_backend_free after umount. */
void *nfsk_backend_from_block(void *block_resource, int allow_write);  /* __bridge FSBlockDeviceResource* */
void *nfsk_backend_from_file(const char *path, int writable, int *out_err);
void  nfsk_backend_free(void *backend);

/* I/O over a backend (the `backend` arg is what nfsk_backend_* returns). */
int64_t  nfsk_block_pread(void *backend, void *buf, int64_t offset, int64_t count);
int64_t  nfsk_block_pwrite(void *backend, const void *buf, int64_t offset, int64_t count);
int      nfsk_block_sync(void *backend);
uint64_t nfsk_block_total_bytes(void *backend);
uint32_t nfsk_block_sector_size(void *backend);
int      nfsk_block_is_writable(void *backend);

#ifdef __cplusplus
}
#endif

#endif /* NTFS_FSKIT_H */
