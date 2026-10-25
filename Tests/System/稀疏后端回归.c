#include "ntfs_fskit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <errno.h>

/* 普通文件后端排除 FSKit 和内核缓存，判断空洞是否在桥接层被实体化。 */
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int error = 0, failed = 0;
    void *backend = nfsk_backend_from_file(argv[1], 1, &error);
    if (!backend) { fprintf(stderr, "打开测试镜像失败：%d\n", error); return 2; }
    ntfs_fskit_volume *volume = nfsk_mount(backend, false, &error);
    if (!volume) { nfsk_backend_free(backend); return 2; }
    for (unsigned index = 0; index < 4; index++) {
        const char *names[] = {"驻留空洞.bin", "非驻留空洞.bin", "驻留先扩长度.bin", "非驻留先扩长度.bin"};
        const char *name = names[index];
        uint64_t ino = nfsk_create(volume, NFSK_ROOT_INO, name, NFSK_TYPE_FILE, &error);
        size_t initial = index % 2 ? 8192 : 4;
        unsigned char prefix[8192], hole[4096];
        memset(prefix, 0x51, sizeof(prefix));
        if (!ino || nfsk_write(volume, ino, 0, prefix, initial, &error) != (int64_t)initial ||
            nfsk_sync(volume) ||
            (index >= 2 && nfsk_truncate(volume, ino, 64 * 1024 * 1024 + 11)) ||
            nfsk_write(volume, ino, 64 * 1024 * 1024 + 7, "TAIL", 4, &error) != 4 || nfsk_sync(volume)) {
            fprintf(stderr, "写入失败：%d\n", error); failed = 1; continue;
        }
        nfsk_attr_t attr;
        if (nfsk_getattr(volume, ino, &attr)) { failed = 1; continue; }
        memset(hole, 1, sizeof(hole));
        int64_t read = nfsk_read(volume, ino, 32 * 1024 * 1024, hole, sizeof(hole), &error);
        int zero = read == sizeof(hole);
        for (size_t i = 0; i < sizeof(hole); i++) if (hole[i]) zero = 0;
        printf("%s：逻辑=%" PRIu64 "，分配=%" PRIu64 "，零洞=%d\n", name, attr.size, attr.alloc_size, zero);
        if (attr.size != 64 * 1024 * 1024 + 11 || attr.alloc_size >= 2 * 1024 * 1024 || !zero) failed = 1;
    }
    /* 复现系统先逐块补零、最后写尾部的顺序，旧文件范围内的零仍必须落盘。 */
    uint64_t filled = nfsk_create(volume, NFSK_ROOT_INO, "系统逐块补零.bin", NFSK_TYPE_FILE, &error);
    unsigned char *block = calloc(1, 1024 * 1024);
    if (!block || !filled) return 2;
    memcpy(block, "HEAD", 4);
    if (nfsk_write(volume, filled, 0, "HEAD", 4, &error) != 4) failed = 1;
    for (int i = 0; i < 64; i++) {
        if (i) memset(block, 0, 1024 * 1024);
        if (nfsk_write(volume, filled, (int64_t)i * 1024 * 1024, block, 1024 * 1024, &error) != 1024 * 1024) failed = 1;
    }
    memcpy(block + 7, "TAIL", 4);
    if (nfsk_write(volume, filled, 64 * 1024 * 1024, block, 11, &error) != 11 || nfsk_sync(volume)) failed = 1;
    nfsk_attr_t filled_attr;
    if (nfsk_getattr(volume, filled, &filled_attr)) failed = 1;
    else {
        printf("系统逐块补零：逻辑=%" PRIu64 "，分配=%" PRIu64 "\n", filled_attr.size, filled_attr.alloc_size);
        if (filled_attr.size != 64 * 1024 * 1024 + 11 || filled_attr.alloc_size >= 2 * 1024 * 1024) failed = 1;
    }
    memset(block, 0, 1024 * 1024);
    if (nfsk_write(volume, filled, 4 * 1024 * 1024, block, 1024 * 1024, &error) != 1024 * 1024 ||
        nfsk_getattr(volume, filled, &filled_attr)) failed = 1;
    else {
        printf("乱序零块覆盖已有空洞：分配=%" PRIu64 "\n", filled_attr.alloc_size);
        if (filled_attr.alloc_size != 8192 || filled_attr.size != 64 * 1024 * 1024 + 11 ||
            nfsk_read(volume, filled, 64 * 1024 * 1024 + 7, block + 16, 4, &error) != 4 ||
            memcmp(block + 16, "TAIL", 4)) failed = 1;
    }
    memset(block, 0, 1024 * 1024);
    memcpy(block, "HEAD", 4);
    if (nfsk_write(volume, filled, 0, block, 1024 * 1024, &error) != 1024 * 1024 ||
        nfsk_getattr(volume, filled, &filled_attr) || filled_attr.alloc_size != 8192) failed = 1;
    memset(block, 0, 1024 * 1024);
    if (nfsk_write(volume, filled, 0, block, 4, &error) != 4 ||
        nfsk_read(volume, filled, 0, block + 8, 4, &error) != 4 || memcmp(block, block + 8, 4)) failed = 1;
    uint64_t mixed = nfsk_create(volume, NFSK_ROOT_INO, "跨旧长度混合尾零.bin", NFSK_TYPE_FILE, &error);
    memset(block, 0x6b, 8192);
    if (!mixed || nfsk_write(volume, mixed, 0, block, 8192, &error) != 8192) failed = 1;
    memset(block, 0, 1024 * 1024);
    memcpy(block, "PREFIX", 6);
    if (nfsk_write(volume, mixed, 4096, block, 1024 * 1024, &error) != 1024 * 1024) failed = 1;
    unsigned char verify[8192];
    if (nfsk_read(volume, mixed, 4090, verify, sizeof(verify), &error) != sizeof(verify)) failed = 1;
    else {
        for (int i = 0; i < 6; i++) if (verify[i] != 0x6b) failed = 1;
        if (memcmp(verify + 6, "PREFIX", 6)) failed = 1;
        for (size_t i = 12; i < sizeof(verify); i++) if (verify[i]) failed = 1;
    }
    if (nfsk_getattr(volume, mixed, &filled_attr) || filled_attr.size != 1024 * 1024 + 4096 ||
        filled_attr.alloc_size >= 32768) failed = 1;
    printf("跨旧长度混合尾零与旧数据覆盖：%s\n", failed ? "此前存在失败" : "通过");
    /* 预分配后扩展逻辑长度：验证已分配但未初始化的区域也必须读零。 */
    uint64_t allocated = nfsk_create(volume, NFSK_ROOT_INO, "预分配零区间.bin", NFSK_TYPE_FILE, &error);
    if (!allocated || nfsk_write(volume, allocated, 0, "HEAD", 4, &error) != 4 ||
        nfsk_preallocate(volume, allocated, 0, 8 * 1024 * 1024, false) < 0 ||
        nfsk_truncate(volume, allocated, 8 * 1024 * 1024) || nfsk_sync(volume)) failed = 1;
    else {
        unsigned char bytes[4096];
        memset(bytes, 1, sizeof(bytes));
        int zero = nfsk_read(volume, allocated, 4 * 1024 * 1024, bytes, sizeof(bytes), &error) == sizeof(bytes);
        for (size_t i = 0; i < sizeof(bytes); i++) if (bytes[i]) zero = 0;
        printf("已分配未初始化区域读零：%d\n", zero);
        if (!zero) failed = 1;
    }
    /* 实际填满这个新建小镜像，确认带零尾的失败写入不会谎报全部成功。 */
    uint64_t full = nfsk_create(volume, NFSK_ROOT_INO, "容量耗尽.bin", NFSK_TYPE_FILE, &error);
    memset(block, 0x35, 1024 * 1024);
    int64_t written = 0, last = 0;
    while (written < 256 * 1024 * 1024) {
        last = nfsk_write(volume, full, written, block, 1024 * 1024, &error);
        if (last <= 0) break;
        written += last;
    }
    if (last != -1 || error != ENOSPC) failed = 1;
    while (written < 256 * 1024 * 1024) {
        last = nfsk_write(volume, full, written, block, 4096, &error);
        if (last <= 0) break;
        written += last;
    }
    if (last != -1 || error != ENOSPC) failed = 1;
    memset(block + 4096, 0, 1024 * 1024 - 4096);
    last = nfsk_write(volume, full, written, block, 1024 * 1024, &error);
    if (last >= 1024 * 1024 || (last < 0 && error != ENOSPC)) failed = 1;
    printf("容量耗尽写入返回=%" PRId64 "，错误=%d\n", last, error);
    free(block);
    nfsk_umount(volume);
    nfsk_backend_free(backend);
    backend = nfsk_backend_from_file(argv[1], 0, &error);
    volume = backend ? nfsk_mount(backend, true, &error) : NULL;
    if (!volume || nfsk_write(volume, mixed, 0, "\0", 1, &error) != -1 || error != EROFS) failed = 1;
    if (volume) nfsk_umount(volume);
    if (backend) nfsk_backend_free(backend);
    printf("只读拒绝零写入：%s\n", error == EROFS ? "通过" : "失败");
    return failed;
}
