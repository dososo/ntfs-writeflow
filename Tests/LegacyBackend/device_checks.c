/* GPL-2.0：真实普通文件模拟raw扇区约束，只验证I/O算法，不冒充物理设备。 */
#include "../../Sources/LegacyBackend/legacy_device.c"
#include <stdio.h>

static int count;
#define CHECK(x) do { count++; if(!(x)) { fprintf(stderr,"失败：%s 第%d行 errno=%d\n",#x,__LINE__,errno);return 1; } } while(0)
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    int fd=open(argv[1],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    CHECK(fd>=0);unsigned char original[4096],expected[4096],got[4096];
    for(size_t i=0;i<sizeof(original);i++)original[i]=(unsigned char)(i%251);
    memcpy(expected,original,sizeof(expected));CHECK(write(fd,original,sizeof(original))==sizeof(original));
    struct device d={.fd=fd,.writable=true,.raw=true,.bytes=sizeof(original),.sector=512};
    CHECK(nfsk_block_pread(&d,got,72,8)==8 && !memcmp(got,original+72,8));
    memset(expected+507,0xa7,17);unsigned char patch[17];memset(patch,0xa7,sizeof(patch));
    CHECK(nfsk_block_pwrite(&d,patch,507,sizeof(patch))==sizeof(patch));
    CHECK(pread(fd,got,sizeof(got),0)==sizeof(got) && !memcmp(got,expected,sizeof(got)));
    CHECK(nfsk_block_pread(&d,got,4090,20)==6 && !memcmp(got,expected+4090,6));
    CHECK(nfsk_block_pread(&d,got,4096,0)==0);
    CHECK(nfsk_block_pwrite(&d,patch,4090,17)==-1 && errno==EINVAL);
    CHECK(nfsk_block_pread(&d,got,-1,1)==-1 && errno==EINVAL);
    d.writable=false;CHECK(nfsk_block_pwrite(&d,patch,0,17)==-1 && errno==EROFS);d.writable=true;
    int error;void *backend=wf_legacy_backend(fd,sizeof(original),false,true,&error);
    CHECK(backend!=NULL && error==0);CHECK(nfsk_block_pwrite(backend,patch,0,17)==-1 && errno==EROFS);
    nfsk_backend_free(backend);CHECK(fcntl(fd,F_GETFD)>=0);
    CHECK(wf_legacy_backend(fd,sizeof(original)-1,false,true,&error)==NULL && error==EINVAL);
    int ro=open(argv[1],O_RDONLY|O_CLOEXEC);CHECK(ro>=0);
    CHECK(wf_legacy_backend(ro,sizeof(original),true,true,&error)==NULL && error==EACCES);close(ro);
    CHECK(wf_legacy_backend(fd,sizeof(original),false,false,&error)==NULL && error==EINVAL);
    int append=open(argv[1],O_RDWR|O_APPEND|O_CLOEXEC);CHECK(append>=0);
    CHECK(wf_legacy_backend(append,sizeof(original),true,true,&error)==NULL && error==EINVAL);
    CHECK(close(append)==0);
    CHECK(ftruncate(fd,300)==0);
    CHECK(nfsk_block_pread(&d,got,72,8)==-1 && errno==EIO);
    CHECK(nfsk_block_pwrite(&d,patch,72,8)==-1 && errno==EIO);
    CHECK(close(fd)==0);CHECK(nfsk_block_sync(&d)==-EBADF);
    printf("通过：%d项FD复制、只读门禁、扇区读改写、短读及关闭故障检查；raw路径为普通文件模拟。\n",count);
    return 0;
}
