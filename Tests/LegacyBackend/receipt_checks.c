/* GPL-2.0：普通文件上的真实两阶段回执与单点I/O故障注入。 */
#include "legacy_receipt.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int count,write_count,sync_count,resize_count,write_fail,sync_fail,resize_fail;
static int zero_write,interrupt_write,sync_fail_from,empty_resize;
static size_t maximum_write;
static const char *token="11111111-2222-4333-8444-555555555555";
static const uint64_t whole=UINT64_C(9876543210);
#define CHECK(x) do {count++;if(!(x)){fprintf(stderr,"失败：%s 第%d行 errno=%d\n",#x,__LINE__,errno);return 1;}}while(0)

static ssize_t writing(int fd,const void *buffer,size_t length,off_t offset) {
    write_count++;
    if(write_count==write_fail){errno=EIO;return -1;}
    if(write_count==interrupt_write){errno=EINTR;return -1;}
    if(write_count==zero_write)return 0;
    if(maximum_write && length>maximum_write)length=maximum_write;
    return pwrite(fd,buffer,length,offset);
}
static int synchronizing(int fd) {
    sync_count++;
    if(sync_count==sync_fail || (sync_fail_from && sync_count>=sync_fail_from)){errno=EIO;return -1;}
    return fsync(fd);
}
static int resizing(int fd,off_t size) {
    resize_count++;
    if(size<=0){empty_resize=1;errno=EINVAL;return -1;}
    if(resize_count==resize_fail){errno=EIO;return -1;}
    return ftruncate(fd,size);
}
static const struct wf_legacy_receipt_io io={writing,synchronizing,resizing};
static void reset(void) {
    write_count=sync_count=resize_count=0;
    write_fail=sync_fail=resize_fail=zero_write=interrupt_write=sync_fail_from=empty_resize=0;
    maximum_write=0;
}
static int marker(int fd) {unsigned char byte=255;return pread(fd,&byte,1,0)==1?byte:-1;}
static int snapshot(int fd,const char *prefix,const char *suffix) {
    char path[4096],bytes[512];struct stat st;
    if(snprintf(path,sizeof(path),"%s.%s",prefix,suffix)>=(int)sizeof(path)||fstat(fd,&st)||st.st_size<=1||st.st_size>(off_t)sizeof(bytes))return -1;
    if(pread(fd,bytes,(size_t)st.st_size,0)!=st.st_size)return -1;
    int out=open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);if(out<0)return -1;
    int result=pwrite(out,bytes,(size_t)st.st_size,0)==st.st_size && fsync(out)==0?0:-1;
    close(out);return result;
}

int main(int argc,char **argv) {
    if(argc!=2 || getuid()<501)return 2;
    int fd=open(argv[1],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);CHECK(fd>=0);
    CHECK(wf_legacy_write_receipt(fd,getuid(),whole,token,0,false)==0 && marker(fd)==0);
    CHECK(snapshot(fd,argv[1],"pending")==0);
    CHECK(wf_legacy_write_receipt(fd,getuid(),whole,token,0,true)==0 && marker(fd)==1);
    CHECK(snapshot(fd,argv[1],"status0")==0);
    CHECK(wf_legacy_write_receipt(fd,getuid(),whole,token,74,true)==0 && marker(fd)==1);
    CHECK(snapshot(fd,argv[1],"status74")==0);

    for(int kind=0;kind<3;kind++)for(int point=1;point<=(kind==2?1:3);point++) {
        CHECK(wf_legacy_write_receipt(fd,getuid(),whole,token,0,false)==0);
        reset();if(kind==0)write_fail=point;else if(kind==1)sync_fail=point;else resize_fail=point;
        CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,0,true,&io)==-EIO);
        CHECK(marker(fd)==0 && !empty_resize);
        struct stat st;CHECK(fstat(fd,&st)==0 && st.st_size>1);
    }
    CHECK(snapshot(fd,argv[1],"syncfail")==0);
    CHECK(wf_legacy_write_receipt(fd,getuid(),whole,token,0,false)==0);
    reset();zero_write=2;
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,0,true,&io)==-EIO && marker(fd)==0);
    reset();maximum_write=3;
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,0,true,&io)==0 && marker(fd)==1);
    CHECK(write_count>10 && resize_count==1 && !empty_resize);
    reset();interrupt_write=2;
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,0,true,&io)==0 && marker(fd)==1);
    reset();sync_fail_from=3;
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,0,true,&io)==-EIO && marker(fd)==0);

    reset();
    CHECK(wf_legacy_write_receipt_with_io(fd,0,whole,token,0,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,UINT32_MAX,whole,token,0,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),0,token,0,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,"11111111-2222-4333-8444-55555555555a",0,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,"\"},\"status\":0",0,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,-1,true,&io)==-EINVAL && write_count==0);
    CHECK(wf_legacy_write_receipt_with_io(fd,getuid(),whole,token,256,true,&io)==-EINVAL && write_count==0);
    CHECK(close(fd)==0);
    printf("通过：%d项初始未知、成功/失败收尾、写同步截断故障、短写、字段边界与无空截断窗口检查。\n",count);
    return 0;
}
