#include "ntfs_fskit.h"
#include <ntfs-3g/attrib.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

/* 只在测试桥编译时替换两个调用入口，真实引擎和正式桥没有故障开关。 */
static int mode, calls;
s64 regression_attr_pwrite(ntfs_attr *attr, s64 offset, s64 count, const void *bytes) {
    if (mode == 1) {
        if (calls++) { errno = EIO; return -1; }
        if (count > 2) count = 2;
    }
    return ntfs_attr_pwrite(attr, offset, count, bytes);
}
int regression_attr_truncate(ntfs_attr *attr, s64 size) {
    if (mode == 2) { errno = ENOSPC; return -1; }
    return ntfs_attr_truncate(attr, size);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int error = 0, failed = 0;
    void *backend = nfsk_backend_from_file(argv[1], 1, &error);
    ntfs_fskit_volume *volume = backend ? nfsk_mount(backend, false, &error) : NULL;
    if (!volume) return 2;
    const char data[12] = {'A', 'B', 'C', 'D'};
    uint64_t edge = nfsk_create(volume, NFSK_ROOT_INO, "长度上界.bin", NFSK_TYPE_FILE, &error);
    char prefix[8192];
    memset(prefix, 0x51, sizeof(prefix));
    if (!edge || nfsk_write(volume, edge, 0, prefix, sizeof(prefix), &error) != sizeof(prefix)) return 2;
    nfsk_attr_t edge_attr;
    if (nfsk_write(volume, edge, INT64_MAX - 1, "\0", 1, &error) != -1 || error != EFBIG ||
        nfsk_getattr(volume, edge, &edge_attr) || edge_attr.size != sizeof(prefix)) failed = 1;
    printf("簇取整长度上界拒绝且旧长度不变：%s\n", failed ? "失败" : "通过");
    for (int i = 0; i < 3; i++) {
        const char *names[] = {"受控短写.bin", "尾零扩展失败.bin", "全零扩展失败.bin"};
        uint64_t ino = nfsk_create(volume, NFSK_ROOT_INO, names[i], NFSK_TYPE_FILE, &error);
        if (!ino) return 2;
        mode = i == 0 ? 1 : 2;
        calls = 0;
        error = 0;
        int64_t result = nfsk_write(volume, ino, 0, data + (i == 2 ? 4 : 0), i == 2 ? 8 : 12, &error);
        mode = 0;
        nfsk_attr_t attr;
        if (nfsk_getattr(volume, ino, &attr)) failed = 1;
        int64_t expected = i == 0 ? 2 : i == 1 ? 4 : -1;
        uint64_t expected_size = i == 0 ? 2 : i == 1 ? 4 : 0;
        if (result != expected || attr.size != expected_size || (i == 2 && error != ENOSPC)) failed = 1;
        char observed[4] = {0};
        if (expected_size && (nfsk_read(volume, ino, 0, observed, expected_size, &error) != (int64_t)expected_size ||
                              memcmp(observed, data, expected_size))) failed = 1;
        printf("%s：返回=%lld，逻辑长度=%llu\n", names[i], (long long)result, (unsigned long long)attr.size);
    }
    nfsk_umount(volume);
    nfsk_backend_free(backend);
    return failed;
}
