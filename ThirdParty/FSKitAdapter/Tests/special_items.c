/* 仅在自建普通文件镜像内预制Interix项，不创建宿主设备节点。 */
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../../NTFSBridge/ntfs_fskit.c"

typedef struct { int fd; int64_t size; } image_backend;
int64_t nfsk_block_pread(void *p, void *b, int64_t o, int64_t n) {
    image_backend *d = p;
    if (o < 0 || n < 0 || o > d->size || n > d->size - o) { errno = EINVAL; return -1; }
    return pread(d->fd, b, (size_t)n, (off_t)o);
}
int64_t nfsk_block_pwrite(void *p, const void *b, int64_t o, int64_t n) {
    image_backend *d = p;
    if (o < 0 || n < 0 || o > d->size || n > d->size - o) { errno = EINVAL; return -1; }
    return pwrite(d->fd, b, (size_t)n, (off_t)o);
}
int nfsk_block_sync(void *p) { return fsync(((image_backend *)p)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *p) { return ((image_backend *)p)->size; }
uint32_t nfsk_block_sector_size(void *p) { (void)p; return 512; }
int nfsk_block_is_writable(void *p) { (void)p; return 1; }

static int checks;
#define CHECK(c, m) do { checks++; if (!(c)) { fprintf(stderr, "失败：%s，errno=%d\n", m, errno); exit(1); } } while (0)
static const char *names[] = {"字符项", "块项", "管道项", "套接字项"};
static const mode_t kinds[] = {S_IFCHR, S_IFBLK, S_IFIFO, S_IFSOCK};
static uint64_t ids[4];

static int listing(void *p, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    (void)ino; (void)cookie;
    int *count = p;
    CHECK(type == NFSK_TYPE_FILE || type == NFSK_TYPE_DIR || type == NFSK_TYPE_SYMLINK, "枚举不能呈现特殊类型");
    for (int i = 0; i < 4; i++) CHECK(strcmp(name, names[i]), "枚举跳过预制特殊项");
    (*count)++;
    return 0;
}

typedef struct { int count; int64_t cookie; uint64_t ino; } page;
static int one_entry(void *p, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    page *result = p;
    listing(&result->count, name, ino, type, cookie);
    result->cookie = cookie; result->ino = ino;
    return 1;
}

int main(int argc, char **argv) {
    CHECK(argc == 3, "显式镜像和凭据输出路径");
    image_backend d = {.fd = open(argv[1], O_RDWR | O_NOFOLLOW | O_CLOEXEC)};
    struct stat st;
    CHECK(d.fd >= 0 && fstat(d.fd, &st) == 0 && S_ISREG(st.st_mode), "只接受普通镜像文件");
    d.size = st.st_size;
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&d, false, &error);
    CHECK(v != NULL, "真实引擎打开自建NTFS镜像");
    v->vol->special_files = NTFS_FILES_INTERIX;
    for (int i = 0; i < 4; i++) {
        ntfs_inode *root = nfsk_inode_open(v->vol, FILE_root);
        ntfschar *name = NULL;
        int n = ntfs_mbstoucs(names[i], &name);
        CHECK(root && n > 0, "准备真实引擎特殊项");
        ntfs_inode *ni = i < 2 ? ntfs_create_device(root, const_cpu_to_le32(0), name, n, kinds[i], makedev(1, 3)) :
            ntfs_create(root, const_cpu_to_le32(0), name, n, kinds[i]);
        free(name);
        CHECK(ni != NULL, "真实引擎预制特殊项，不调用宿主mknod");
        CHECK(nfsk_inode_type(ni) >= NFSK_TYPE_FIFO, "fixture确为特殊类型，不能用普通文件假测");
        ids[i] = from_mft(ni->mft_no);
        CHECK(nfsk_inode_close(ni) == 0 && nfsk_inode_close(root) == 0, "保存预制项");
    }
    uint64_t normal = nfsk_create(v, NFSK_ROOT_INO, "普通文件", NFSK_TYPE_FILE, &error);
    uint64_t directory = nfsk_create(v, NFSK_ROOT_INO, "普通目录", NFSK_TYPE_DIR, &error);
    uint64_t link = nfsk_symlink(v, NFSK_ROOT_INO, "普通链接", "普通文件", &error);
    CHECK(normal && directory && link, "普通文件目录链接对照真实创建");
    CHECK(nfsk_sync(v) == 0, "预制镜像同步");
    FILE *out = fopen(argv[2], "wx");
    CHECK(out != NULL, "凭据输出不覆盖旧文件");
    fprintf(out, "[%llu,%llu,%llu,%llu]\n", ids[0], ids[1], ids[2], ids[3]);
    CHECK(fclose(out) == 0, "保存测试inode列表");
    for (int ro = 0; ro <= 1; ro++) {
        if (ro) {
            CHECK(nfsk_umount(v) == 0, "关闭可写fixture");
            v = nfsk_mount(&d, true, &error);
            CHECK(v != NULL, "只读重新打开同一fixture");
        }
        for (int i = 0; i < 4; i++) {
            nfsk_attr_t a;
            CHECK(nfsk_getattr(v, ids[i], &a) == -ENOTSUP, "getattr拒绝特殊项");
            error = 0;
            CHECK(nfsk_lookup(v, NFSK_ROOT_INO, names[i], &error) == 0 && error == ENOTSUP, "lookup拒绝预制特殊项");
            char canonical[128]; error = 0;
            CHECK(nfsk_lookup_name(v, NFSK_ROOT_INO, names[i], canonical, sizeof(canonical), &error) == 0 && error == ENOTSUP,
                  "有规范名的lookup也拒绝特殊项");
            CHECK(nfsk_open_item(v, ids[i]) == -ENOTSUP, "持有已知inode仍不能打开特殊项");
        }
        int count = 0;
        CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, &count, listing) == 0 && count == 3, "跳过特殊项不破坏普通目录枚举");
        page next = {0};
        uint64_t previous[3];
        int pages = 0;
        for (;;) {
            next.count = 0;
            CHECK(nfsk_readdir(v, NFSK_ROOT_INO, next.cookie, &next, one_entry) == 0, "带cookie继续枚举不报错");
            if (!next.count) break;
            CHECK(pages < 3, "跳过特殊项后分页不循环");
            for (int i = 0; i < pages; i++) CHECK(previous[i] != next.ino, "分页不重复普通项");
            previous[pages++] = next.ino;
        }
        CHECK(pages == 3, "分页没有丢失普通项");
        const uint64_t ordinary[] = {normal, directory, link};
        for (int i = 0; i < 3; i++) {
            nfsk_attr_t a;
            CHECK(nfsk_getattr(v, ordinary[i], &a) == 0 && (a.mode & 06000) == 0, "真实getattr无setuid/setgid位");
        }
    }
    CHECK(nfsk_umount(v) == 0 && close(d.fd) == 0, "仅关闭测试普通镜像");
    printf("通过：%d项真实引擎特殊项拒绝与权限边界；未挂载、未打开宿主设备。\n", checks);
    return 0;
}
