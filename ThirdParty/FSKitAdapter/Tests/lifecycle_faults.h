#include "ntfs_fskit.h"
/* 仅测试链接产物提供的故障控制，正式扩展不包含此头文件。 */
void nfsk_test_fail_sync(int enabled);
void nfsk_test_fail_close(int enabled);

void nfsk_test_fail_preflight(int reason);
