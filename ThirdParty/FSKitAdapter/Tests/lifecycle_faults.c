#include "lifecycle_faults.h"
#include <errno.h>

static int fail_sync;
int nfsk_sync_real(ntfs_fskit_volume *volume);
void nfsk_test_fail_sync(int enabled) { fail_sync = enabled; }
/* 只拦截适配层调用；引擎关闭路径仍调用真实同步，不加入正式产品开关。 */
int nfsk_sync(ntfs_fskit_volume *volume) {
    return fail_sync ? -EIO : nfsk_sync_real(volume);
}

static int fail_close;
int nfsk_umount_real(ntfs_fskit_volume *volume);
void nfsk_test_fail_close(int enabled) { fail_close = enabled; }
/* 真实关闭后注入桥接边界错误，保持句柄始终消费的正式契约。 */
int nfsk_umount(ntfs_fskit_volume *volume) {
    int rc = nfsk_umount_real(volume);
    return rc ? rc : (fail_close ? -EIO : 0);
}

static int fail_preflight;
int nfsk_quick_check_real(void *resource, int *reason);
void nfsk_test_fail_preflight(int reason) { fail_preflight = reason; }
int nfsk_quick_check(void *resource, int *reason) {
    if (fail_preflight) { if (reason) *reason = fail_preflight; return -EIO; }
    return nfsk_quick_check_real(resource, reason);
}
