#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "ntfs_fskit.h"

// 仅模拟 FSKit 的块资源消息，不创建块设备、不挂载、不访问真实磁盘。
@interface TestBlock : NSObject
@property uint64_t blockSize;
@property uint64_t blockCount;
@property uint64_t physicalBlockSize;
@property(getter=isWritable) BOOL writable;
@property BOOL shortRead;
@property BOOL flushFailure;
@property NSMutableData *storage;
@end
@implementation TestBlock
- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    if (self.shortRead) return 1;
    memcpy(buffer, (const char *)self.storage.bytes + offset, length);
    return length;
}
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    memcpy((char *)self.storage.mutableBytes + offset, buffer, length);
    return length;
}
- (BOOL)metadataFlushWithError:(NSError **)error { return !self.flushFailure; }
@end

static int passed;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr,"失败：%s，行 %d\n",message,__LINE__); return 1; } passed++; } while (0)

int main(void) { @autoreleasepool {
    char path[] = "/tmp/blntfs-adapter-XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0 && ftruncate(fd, 4096) == 0, "创建普通临时文件");
    close(fd);
    int error = 0;
    void *file = nfsk_backend_from_file(path, 1, &error);
    CHECK(file != NULL, "打开普通文件后端");
    char payload[128], result[128]; memset(payload, 0x5a, sizeof(payload));
    CHECK(nfsk_block_pwrite(file,payload,4080,INT64_MAX) == 16, "巨大写入长度安全截断到文件边界");
    CHECK(nfsk_block_pread(file,result,4080,INT64_MAX) == 16 && memcmp(payload,result,16) == 0, "巨大读取长度不溢出");
    CHECK(nfsk_block_pread(file,result,-1,1) == -1 && errno == EINVAL, "拒绝负偏移");
    CHECK(nfsk_block_pwrite(file,payload,4096,1) == -1 && errno == ENOSPC, "拒绝尾后写入");
    CHECK(nfsk_block_sync(file) == 0, "普通文件同步");
    nfsk_backend_free(file);
    file = nfsk_backend_from_file(path, 0, &error);
    CHECK(file != NULL, "重新只读打开");
    CHECK(nfsk_block_pwrite(file,payload,0,1) == -1 && errno == EROFS, "只读写入拒绝");
    CHECK(nfsk_block_pread(file,result,4080,16) == 16 && memcmp(payload,result,16) == 0, "重新打开内容保留");
    nfsk_backend_free(file);
    CHECK(unlink(path) == 0, "清理本测试单个临时文件");
    CHECK(nfsk_backend_from_file("/private/tmp", 0, &error) == NULL && error == EINVAL, "拒绝目录伪装镜像");

    TestBlock *block = [TestBlock new];
    block.blockSize=512; block.physicalBlockSize=4096; block.blockCount=16;
    block.writable=YES; block.storage=[NSMutableData dataWithLength:8192];
    memset(block.storage.mutableBytes,0x11,8192);
    void *device=nfsk_backend_from_block((__bridge void *)block,1);
    CHECK(device != NULL, "模拟块资源初始化");
    CHECK(nfsk_block_pwrite(device,payload,8190,INT64_MAX) == 2, "块资源尾部写入安全截断");
    CHECK(nfsk_block_pwrite(device,payload,17,10) == 10, "非对齐写入");
    CHECK(((unsigned char *)block.storage.bytes)[16] == 0x11 && ((unsigned char *)block.storage.bytes)[27] == 0x11, "读改写保留相邻字节");
    CHECK(nfsk_block_pread(device,result,17,10) == 10 && memcmp(payload,result,10) == 0, "非对齐读取");
    block.shortRead=YES;
    CHECK(nfsk_block_pread(device,result,0,10) == -1 && errno == EIO, "非整扇区短读拒绝");
    block.shortRead=NO; block.flushFailure=YES;
    CHECK(nfsk_block_sync(device) == -EIO, "无 NSError 的同步失败仍返回错误");
    nfsk_backend_free(device);
    device=nfsk_backend_from_block((__bridge void *)block,0);
    CHECK(device != NULL && nfsk_block_pwrite(device,payload,0,1) == -1 && errno == EROFS, "可写设备上的只读挂载仍拒绝写入");
    nfsk_backend_free(device);
    block.blockCount=UINT64_MAX;
    CHECK(nfsk_backend_from_block((__bridge void *)block,1) == NULL, "拒绝设备容量乘法溢出");
    printf("适配层安全测试通过：%d 项；仅普通临时文件与模拟块资源。\n",passed);
    return 0;
} }
