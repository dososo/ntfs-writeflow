#include "ntfs_fskit.h"
#include <errno.h>
static int writable_mounts, pwrites;
ntfs_fskit_volume *nfsk_mount_real(void *, bool, int *);
int64_t nfsk_block_pwrite_real(void *, const void *, int64_t, int64_t);
void koio_trace_reset(void) { writable_mounts = pwrites = 0; }
int koio_trace_writable_mounts(void) { return writable_mounts; }
int koio_trace_pwrites(void) { return pwrites; }
ntfs_fskit_volume *nfsk_mount(void *b, bool ro, int *e) {
    if (!ro) writable_mounts++;
    return nfsk_mount_real(b, ro, e);
}
int64_t nfsk_block_pwrite(void *b, const void *data, int64_t off, int64_t count) {
    pwrites++;
    return nfsk_block_pwrite_real(b, data, off, count);
}
#ifdef WF_READY_IO_TRACE
static int reads, syncs, fail_sync;
int64_t nfsk_block_pread_real(void *, void *, int64_t, int64_t);
int nfsk_block_sync_real(void *);
int koio_trace_reads(void) { return reads; }
int koio_trace_syncs(void) { return syncs; }
void koio_trace_fail_sync(int enabled) { fail_sync = enabled; }
int64_t nfsk_block_pread(void *b, void *data, int64_t off, int64_t count) {
    reads++;
    return nfsk_block_pread_real(b, data, off, count);
}
int nfsk_block_sync(void *b) {
    syncs++;
    return fail_sync ? -EIO : nfsk_block_sync_real(b);
}
#endif
