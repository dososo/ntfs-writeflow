/* GPL-2.0：兼容后端复用现有NTFS桥，不实现新的磁盘格式算法。 */
#ifndef WRITEFLOW_LEGACY_VOLUME_H
#define WRITEFLOW_LEGACY_VOLUME_H
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <stdbool.h>
#include <stdint.h>

/* 文件镜像仅由测试直接传入；产品入口必须为字符设备。复制FD，不接管调用者FD。 */
int wf_legacy_start(int descriptor, uint64_t bytes, bool readonly, uid_t uid, bool allow_file);
int wf_legacy_finish(void);
const struct fuse_operations *wf_legacy_operations(void);
void *wf_legacy_backend(int descriptor, uint64_t bytes, bool writable, bool allow_file, int *error);
/* owner与路径由产品入口固定派生；返回独立持锁FD或负errno。 */
int wf_legacy_hold_lease(int descriptor, uid_t owner, const char *path);
int wf_legacy_mount_options(char *buffer, size_t capacity, bool readonly, const char *device);
#endif
