/* GPL-2.0：整盘媒体锁上的两阶段收尾回执。 */
#ifndef WRITEFLOW_LEGACY_RECEIPT_H
#define WRITEFLOW_LEGACY_RECEIPT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct wf_legacy_receipt_io {
    ssize_t (*write_at)(int, const void *, size_t, off_t);
    int (*synchronize)(int);
    int (*resize)(int, off_t);
};

/* 调用方必须持续持有已核验的整盘租约。complete仅编码为byte0，不写入JSON。
 * 返回0或负errno；任何失败都不允许开始写入或报告干净关闭。 */
int wf_legacy_write_receipt(int descriptor, uint32_t user_id, uint64_t whole_media_id,
                           const char *token, int status, bool complete);
/* 仅供故障注入测试；产品入口始终使用上面的固定系统I/O包装。 */
int wf_legacy_write_receipt_with_io(int descriptor, uint32_t user_id, uint64_t whole_media_id,
                                   const char *token, int status, bool complete,
                                   const struct wf_legacy_receipt_io *io);
#endif
