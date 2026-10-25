/* 本项目新增，2026-10-25；GPL-2.0。仅接受普通文件镜像，不接受设备。 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int writable; int fail_sync; int64_t size; } image_device;
static int checks;
#define REQUIRE(condition, message) do { checks++; if (!(condition)) { \
    fprintf(stderr, "失败：%s（errno=%d）\n", message, errno); exit(1); \
} printf("通过：%s\n", message); } while (0)

int64_t nfsk_block_pread(void *opaque, void *buffer, int64_t offset, int64_t count) {
    image_device *d = opaque;
    if (offset < 0 || count < 0 || offset > d->size) { errno = EINVAL; return -1; }
    if (count > d->size - offset) count = d->size - offset;
    return pread(d->fd, buffer, (size_t)count, (off_t)offset);
}
int64_t nfsk_block_pwrite(void *opaque, const void *buffer, int64_t offset, int64_t count) {
    image_device *d = opaque;
    if (!d->writable) { errno = EROFS; return -1; }
    if (offset < 0 || count < 0 || offset > d->size || count > d->size - offset) {
        errno = EINVAL; return -1;
    }
    return pwrite(d->fd, buffer, (size_t)count, (off_t)offset);
}
int nfsk_block_sync(void *opaque) {
    image_device *d = opaque;
    if (d->fail_sync) return -EIO;
    return fsync(d->fd) == 0 ? 0 : -errno;
}
uint64_t nfsk_block_total_bytes(void *opaque) { return ((image_device *)opaque)->size; }
uint32_t nfsk_block_sector_size(void *opaque) { (void)opaque; return 512; }
int nfsk_block_is_writable(void *opaque) { return ((image_device *)opaque)->writable; }

static uint64_t find(ntfs_fskit_volume *v, uint64_t parent, const char *name) {
    int error = 0;
    uint64_t item = nfsk_lookup(v, parent, name, &error);
    REQUIRE(item != 0 && error == 0, "读取已写入的目录项");
    return item;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[1], "写入") && strcmp(argv[1], "只读"))) {
        fprintf(stderr, "用法：离线测试 写入或只读 新建测试镜像 导出文件\n"); return 2;
    }
    int readonly = !strcmp(argv[1], "只读");
    image_device device = {.fd = open(argv[2], (readonly ? O_RDONLY : O_RDWR) | O_NOFOLLOW),
                           .writable = !readonly};
    struct stat st;
    REQUIRE(device.fd >= 0 && fstat(device.fd, &st) == 0 && S_ISREG(st.st_mode), "目标为普通文件镜像");
    device.size = st.st_size;
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, readonly, &error);
    REQUIRE(v != NULL && error == 0, "引擎打开真实 NTFS 镜像");
    nfsk_statfs_t stats;
    REQUIRE(nfsk_statfs(v, &stats) == 0 && stats.read_only == readonly, "实际只读标志与请求一致");
    uint64_t dir, item;
    if (!readonly) {
        dir = nfsk_create(v, NFSK_ROOT_INO, "中文资料", NFSK_TYPE_DIR, &error);
        REQUIRE(dir != 0 && error == 0, "创建中文目录");
        item = nfsk_create(v, NFSK_ROOT_INO, "原始数据.bin", NFSK_TYPE_FILE, &error);
        REQUIRE(item != 0 && error == 0, "创建中文文件");
        unsigned char data[65573];
        for (size_t i = 0; i < sizeof(data); i++) data[i] = (unsigned char)((i * 29 + 7) % 251);
        REQUIRE(nfsk_write(v, item, 0, data, sizeof(data), &error) == sizeof(data), "写入非整扇区长度数据");
        unsigned char patch[97]; memset(patch, 0xa5, sizeof(patch));
        REQUIRE(nfsk_write(v, item, 4093, patch, sizeof(patch), &error) == sizeof(patch), "跨簇边界覆盖");
        unsigned char tail[777]; memset(tail, 0x5a, sizeof(tail));
        REQUIRE(nfsk_write(v, item, sizeof(data), tail, sizeof(tail), &error) == sizeof(tail), "追加写入");
        REQUIRE(nfsk_truncate(v, item, 51113) == 0, "缩短文件");
        REQUIRE(nfsk_truncate(v, item, 62000) == 0, "扩展文件并保留零填充语义");
        REQUIRE(nfsk_rename(v, NFSK_ROOT_INO, "原始数据.bin", dir, "结果.bin") == 0, "跨目录中文路径重命名");
        uint64_t old = nfsk_create(v, dir, "最终.bin", NFSK_TYPE_FILE, &error);
        REQUIRE(old != 0 && nfsk_write(v, old, 0, "旧内容", strlen("旧内容"), &error) == strlen("旧内容"), "准备覆盖重命名目标");
        REQUIRE(nfsk_rename(v, dir, "结果.bin", dir, "最终.bin") == 0, "覆盖重命名");
        REQUIRE(nfsk_sync(v) == 0, "同步数据和元数据");
        device.fail_sync = 1;
        REQUIRE(nfsk_sync(v) == -EIO, "同步故障不能报告成功");
        device.fail_sync = 0;
        (void)nfsk_sync(v);
        REQUIRE(nfsk_sync(v) == 0, "移除同步故障后可恢复");
        nfsk_umount(v);
        REQUIRE(close(device.fd) == 0, "关闭镜像文件描述符");
        device.fd = open(argv[2], O_RDWR | O_NOFOLLOW);
        REQUIRE(device.fd >= 0, "重新打开镜像文件描述符");
        v = nfsk_mount(&device, false, &error);
        REQUIRE(v != NULL && error == 0, "重新打开 NTFS 卷");
    }
    dir = find(v, NFSK_ROOT_INO, "中文资料");
    item = find(v, dir, "最终.bin");
    nfsk_attr_t attr;
    REQUIRE(nfsk_getattr(v, item, &attr) == 0 && attr.size == 62000, "重打开后的文件长度正确");
    unsigned char readback[62001] = {0};
    REQUIRE(nfsk_read(v, item, 0, readback, sizeof(readback), &error) == 62000, "读取完整最终内容并正确报告文件尾");
    int out = open(argv[3], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    REQUIRE(out >= 0 && write(out, readback, 62000) == 62000 && close(out) == 0, "导出到独立预期值校验文件");
    if (readonly) {
        error = 0;
        REQUIRE(nfsk_write(v, item, 0, "禁止", strlen("禁止"), &error) < 0 && error == EROFS, "只读卷拒绝写入");
        error = 0;
        REQUIRE(nfsk_create(v, dir, "不得创建.txt", NFSK_TYPE_FILE, &error) == 0 && error == EROFS, "只读卷拒绝创建");
        REQUIRE(nfsk_truncate(v, item, 0) == -EROFS, "只读卷拒绝截断");
        REQUIRE(nfsk_remove(v, dir, "最终.bin") == -EROFS, "只读卷拒绝删除");
    } else REQUIRE(nfsk_sync(v) == 0, "关闭前同步");
    nfsk_umount(v);
    REQUIRE(close(device.fd) == 0, "结束时关闭镜像");
    printf("检查总数：%d；失败：0\n", checks);
    return 0;
}
