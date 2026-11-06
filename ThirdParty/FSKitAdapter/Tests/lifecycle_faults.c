#include "lifecycle_faults.h"
#include <errno.h>

static int fail_sync;
static int sync_calls, close_calls;
void nfsk_test_reset_calls(void) { sync_calls = close_calls = 0; }
int nfsk_test_sync_calls(void) { return sync_calls; }
int nfsk_test_close_calls(void) { return close_calls; }
int nfsk_sync_real(ntfs_fskit_volume *volume);
void nfsk_test_fail_sync(int enabled) { fail_sync = enabled; }
/* 只拦截适配层调用；引擎关闭路径仍调用真实同步，不加入正式产品开关。 */
int nfsk_sync(ntfs_fskit_volume *volume) {
    sync_calls++;
    return fail_sync ? -EIO : nfsk_sync_real(volume);
}

static int fail_close;
int nfsk_umount_real(ntfs_fskit_volume *volume);
void nfsk_test_fail_close(int enabled) { fail_close = enabled; }
/* 真实关闭后注入桥接边界错误，保持句柄始终消费的正式契约。 */
int nfsk_umount(ntfs_fskit_volume *volume) {
    close_calls++;
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
