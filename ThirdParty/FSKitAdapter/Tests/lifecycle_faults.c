#include "lifecycle_faults.h"
#include <errno.h>

static int fail_sync;
int nfsk_sync_real(ntfs_fskit_volume *volume);
void nfsk_test_fail_sync(int enabled) { fail_sync = enabled; }
/* 只拦截适配层调用；引擎关闭路径仍调用真实同步，不加入正式产品开关。 */
int nfsk_sync(ntfs_fskit_volume *volume) {
    return fail_sync ? -EIO : nfsk_sync_real(volume);
}
