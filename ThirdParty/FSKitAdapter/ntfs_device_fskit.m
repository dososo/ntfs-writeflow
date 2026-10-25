/*
 * ntfs_device_fskit.m - Block I/O backend for the NTFS bridge.
 *
 * A backend wraps one of two sources behind a single C interface (nfsk_block_*):
 *   - NFSKModeBlock: an FSKit FSBlockDeviceResource (a real disk/partition).
 *     FSBlockDeviceResource requires sector-aligned offsets/lengths, so partial
 *     accesses are handled with read-modify-write.
 *   - NFSKModeFile:  an opened image file (FSPathURLResource). A regular file
 *     descriptor supports arbitrary pread/pwrite, so no alignment is needed.
 *
 * No libntfs headers here on purpose: libntfs's `enum BOOL` collides with ObjC's BOOL.
 */

#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#include "ntfs_fskit.h"

typedef NS_ENUM(int, NFSKMode) { NFSKModeBlock = 0, NFSKModeFile = 1 };

@interface NFSKBackend : NSObject {
@public
    NFSKMode               mode;
    FSBlockDeviceResource *block;     /* NFSKModeBlock (strong) */
    int                    fd;        /* NFSKModeFile */
    uint64_t               fileSize;  /* NFSKModeFile */
    BOOL                   writable;
}
@end
@implementation NFSKBackend @end

static inline NFSKBackend *BK(void *backend) { return (__bridge NFSKBackend *)backend; }

/* ------------------------------------------------------------------ */
/* Backend lifecycle.                                                  */
/* ------------------------------------------------------------------ */
void *nfsk_backend_from_block(void *block_resource, int allow_write) {
    FSBlockDeviceResource *resource = (__bridge FSBlockDeviceResource *)block_resource;
    if (!resource || resource.blockSize == 0 || resource.blockCount == 0 ||
        resource.blockSize > UINT32_MAX || resource.physicalBlockSize > UINT32_MAX ||
        resource.blockCount > INT64_MAX / resource.blockSize ||
        (resource.physicalBlockSize && resource.physicalBlockSize % resource.blockSize != 0)) {
        errno = EINVAL;
        return NULL;
    }
    NFSKBackend *b = [NFSKBackend new];
    b->mode = NFSKModeBlock;
    b->block = (__bridge FSBlockDeviceResource *)block_resource;   /* strong ivar retains */
    b->fd = -1;
    /* Honor the caller's read-only intent at the backend: writes are gated unless the
       operation allows writing AND the media is writable. */
    b->writable = (allow_write && b->block.isWritable) ? YES : NO;
    return (void *)CFBridgingRetain(b);
}

void *nfsk_backend_from_file(const char *path, int writable, int *out_err) {
    /* 文件资源只接受普通镜像文件；避免打开设备、符号链接或阻塞管道。 */
    int fd = open(path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) { if (out_err) *out_err = errno; return NULL; }
    struct stat st;
    if (fstat(fd, &st) != 0) { if (out_err) *out_err = errno; close(fd); return NULL; }
    if (!S_ISREG(st.st_mode) || st.st_size <= 0) {
        if (out_err) *out_err = EINVAL;
        close(fd);
        return NULL;
    }
    NFSKBackend *b = [NFSKBackend new];
    b->mode = NFSKModeFile;
    b->fd = fd;
    b->fileSize = (uint64_t)st.st_size;
    b->writable = writable ? YES : NO;
    return (void *)CFBridgingRetain(b);
}

void nfsk_backend_free(void *backend) {
    if (!backend) return;
    NFSKBackend *b = (NFSKBackend *)CFBridgingRelease(backend);
    if (b->mode == NFSKModeFile && b->fd >= 0) { close(b->fd); b->fd = -1; }
    b->block = nil;
}

/* ------------------------------------------------------------------ */
/* Block-device (FSBlockDeviceResource) helpers — sector aligned.      */
/* ------------------------------------------------------------------ */
static uint32_t sector_of(FSBlockDeviceResource *res) {
    uint32_t s = (uint32_t)res.physicalBlockSize;
    if (s == 0) s = (uint32_t)res.blockSize;
    if (s == 0) s = 512;
    return s;
}

static int aligned_read(FSBlockDeviceResource *res, void *buf, int64_t offset, int64_t span) {
    int64_t done = 0;
    while (done < span) {
        NSError *err = nil;
        size_t got = [res readInto:(char *)buf + done startingAt:offset + done
                           length:(size_t)(span - done) error:&err];
        if (err != nil) return -(int)(err.code ? err.code : EIO);
        if (got == 0 || got > (uint64_t)(span - done) ||
            (got < (uint64_t)(span - done) && got % res.blockSize != 0)) return -EIO;
        done += (int64_t)got;
    }
    return 0;
}

static int aligned_write(FSBlockDeviceResource *res, const void *buf, int64_t offset, int64_t span) {
    int64_t done = 0;
    while (done < span) {
        NSError *err = nil;
        size_t put = [res writeFrom:(void *)((const char *)buf + done) startingAt:offset + done
                            length:(size_t)(span - done) error:&err];
        if (err != nil) return -(int)(err.code ? err.code : EIO);
        if (put == 0 || put > (uint64_t)(span - done) ||
            (put < (uint64_t)(span - done) && put % res.blockSize != 0)) return -EIO;
        done += (int64_t)put;
    }
    return 0;
}

static int64_t block_pread(FSBlockDeviceResource *res, void *buf, int64_t offset, int64_t count) {
    int64_t total = (int64_t)((uint64_t)res.blockCount * (uint64_t)res.blockSize);
    if (offset >= total) return 0;
    if (count > total - offset) count = total - offset;

    uint32_t sector = sector_of(res);
    int64_t aligned_start = offset - (offset % sector);
    int64_t end = offset + count; // count 已按 total - offset 截断。
    int64_t padding = end % sector == 0 ? 0 : sector - end % sector;
    int64_t aligned_end = padding > total - end ? total : end + padding;
    int64_t span = aligned_end - aligned_start;

    if (aligned_start == offset && (count % sector) == 0 && aligned_end == offset + count) {
        int rc = aligned_read(res, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    void *tmp = malloc((size_t)span);
    if (!tmp) { errno = ENOMEM; return -1; }
    int rc = aligned_read(res, tmp, aligned_start, span);
    if (rc < 0) { free(tmp); errno = -rc; return -1; }
    memcpy(buf, (char *)tmp + (offset - aligned_start), (size_t)count);
    free(tmp);
    return count;
}

static int64_t block_pwrite(FSBlockDeviceResource *res, const void *buf, int64_t offset, int64_t count) {
    if (!res.isWritable) { errno = EROFS; return -1; }
    int64_t total = (int64_t)((uint64_t)res.blockCount * (uint64_t)res.blockSize);
    if (offset >= total) { errno = ENOSPC; return -1; }
    if (count > total - offset) count = total - offset;

    uint32_t sector = sector_of(res);
    int64_t aligned_start = offset - (offset % sector);
    int64_t end = offset + count; // count 已按 total - offset 截断。
    int64_t padding = end % sector == 0 ? 0 : sector - end % sector;
    int64_t aligned_end = padding > total - end ? total : end + padding;
    int64_t span = aligned_end - aligned_start;

    if (aligned_start == offset && aligned_end == offset + count) {
        int rc = aligned_write(res, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    void *tmp = malloc((size_t)span);
    if (!tmp) { errno = ENOMEM; return -1; }
    int rc = aligned_read(res, tmp, aligned_start, span);
    if (rc < 0) { free(tmp); errno = -rc; return -1; }
    memcpy((char *)tmp + (offset - aligned_start), buf, (size_t)count);
    rc = aligned_write(res, tmp, aligned_start, span);
    free(tmp);
    if (rc < 0) { errno = -rc; return -1; }
    return count;
}

/* ------------------------------------------------------------------ */
/* Public I/O interface — dispatches on backend mode.                  */
/* ------------------------------------------------------------------ */
uint32_t nfsk_block_sector_size(void *backend) {
    NFSKBackend *b = BK(backend);
    return (b->mode == NFSKModeBlock) ? sector_of(b->block) : 512;
}

uint64_t nfsk_block_total_bytes(void *backend) {
    NFSKBackend *b = BK(backend);
    if (b->mode == NFSKModeBlock) return (uint64_t)b->block.blockCount * (uint64_t)b->block.blockSize;
    return b->fileSize;
}

int nfsk_block_is_writable(void *backend) { return BK(backend)->writable ? 1 : 0; }

int64_t nfsk_block_pread(void *backend, void *buf, int64_t offset, int64_t count) {
    if (offset < 0 || count < 0) { errno = EINVAL; return -1; }
    if (count == 0) return 0;
    NFSKBackend *b = BK(backend);
    if (b->mode == NFSKModeFile) {
        int64_t total = (int64_t)b->fileSize;
        if (offset >= total) return 0;
        if (count > total - offset) count = total - offset;
        ssize_t n = pread(b->fd, buf, (size_t)count, (off_t)offset);
        if (n < 0) return -1;
        return n;
    }
    return block_pread(b->block, buf, offset, count);
}

int64_t nfsk_block_pwrite(void *backend, const void *buf, int64_t offset, int64_t count) {
    if (offset < 0 || count < 0) { errno = EINVAL; return -1; }
    if (count == 0) return 0;
    NFSKBackend *b = BK(backend);
    if (!b->writable) { errno = EROFS; return -1; }
    if (b->mode == NFSKModeFile) {
        int64_t total = (int64_t)b->fileSize;
        if (offset >= total) { errno = ENOSPC; return -1; }
        if (count > total - offset) count = total - offset;
        ssize_t n = pwrite(b->fd, buf, (size_t)count, (off_t)offset);
        if (n < 0) return -1;
        return n;
    }
    return block_pwrite(b->block, buf, offset, count);
}

int nfsk_block_sync(void *backend) {
    NFSKBackend *b = BK(backend);
    if (b->mode == NFSKModeFile) {
        return fsync(b->fd) == 0 ? 0 : -errno;
    }
    NSError *err = nil;
    if (![b->block metadataFlushWithError:&err]) {
        return -(int)(err.code ? err.code : EIO);
    }
    return 0;
}
