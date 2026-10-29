/* 仅新建文件镜像加载到内存后生成合成状态；不写回文件或访问设备。 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ntfs_fskit.h"
typedef struct { unsigned char *bytes; int64_t size; int writes; int fail_read; } memory_device;
int64_t nfsk_block_pread(void *opaque, void *buf, int64_t off, int64_t len) {
    memory_device *d=opaque;
    if(d->fail_read){errno=EIO;return -1;}
    if(off<0 || len<0 || off>d->size || len>d->size-off){errno=EINVAL;return -1;}
    memcpy(buf,d->bytes+off,(size_t)len);return len;
}
int64_t nfsk_block_pwrite(void *opaque,const void *buf,int64_t off,int64_t len) {
    memory_device *d=opaque;d->writes++;
    if(off<0 || len<0 || off>d->size || len>d->size-off){errno=EINVAL;return -1;}
    memcpy(d->bytes+off,buf,(size_t)len);return len;
}
int nfsk_block_sync(void *opaque){(void)opaque;return 0;}
uint64_t nfsk_block_total_bytes(void *opaque){return ((memory_device*)opaque)->size;}
uint32_t nfsk_block_sector_size(void *opaque){(void)opaque;return 512;}
int nfsk_block_is_writable(void *opaque){(void)opaque;return 1;}
/* 同一实际桥接翻译单元；仅测试读取内部卷以生成状态，不添加产品故障开关。 */
#include "../../NTFSBridge/ntfs_fskit.c"
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"预检测试失败 line=%d errno=%d\n",__LINE__,errno);exit(1);}}while(0)
int main(int argc,char **argv){
 REQUIRE(argc==2);
 int fd=open(argv[1],O_RDONLY|O_NOFOLLOW);struct stat st;
 REQUIRE(fd>=0 && fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_size==64*1024*1024);
 memory_device d={.size=st.st_size};
 unsigned char *original=malloc(d.size),*before=malloc(d.size);d.bytes=malloc(d.size);
 REQUIRE(original&&before&&d.bytes && read(fd,original,d.size)==d.size);close(fd);
 const char *names[]={"干净卷","脏卷标记","休眠头","损坏日志","坏引导区","后端读取EIO"};
 for(int mode=0;mode<6;mode++){
  memcpy(d.bytes,original,d.size);d.fail_read=0;
  if(mode>=1 && mode<=3){
   int e=0;ntfs_fskit_volume *v=nfsk_mount(&d,false,&e);REQUIRE(v&&e==0);
   if(mode==1) REQUIRE(ntfs_volume_write_flags(v->vol,VOLUME_IS_DIRTY)==0);
   if(mode==2){uint64_t i=nfsk_create(v,NFSK_ROOT_INO,"hiberfil.sys",NFSK_TYPE_FILE,&e);REQUIRE(i&&e==0);unsigned char h[4096]={0};memcpy(h,"hibr",4);REQUIRE(nfsk_write(v,i,0,h,sizeof(h),&e)==sizeof(h));}
   if(mode==3){ntfs_inode *ni=ntfs_inode_open(v->vol,FILE_LogFile);REQUIRE(ni);ntfs_attr *na=ntfs_attr_open(ni,AT_DATA,AT_UNNAMED,0);REQUIRE(na);unsigned char h[4096]={0};memcpy(h,"BAD!",4);REQUIRE(ntfs_attr_pwrite(na,0,sizeof(h),h)==sizeof(h));ntfs_attr_close(na);REQUIRE(ntfs_inode_close(ni)==0);}
   REQUIRE(nfsk_umount(v)==0);
  }
  if(mode==4) memset(d.bytes,0,512);
  if(mode==5)d.fail_read=1;
  memcpy(before,d.bytes,d.size);d.writes=0;int reason=-1;int rc=nfsk_quick_check(&d,&reason);
  if(mode==0)REQUIRE(rc==0 && reason==NFSK_CHECK_CLEAN);else REQUIRE(rc<0);
  if(mode==1)REQUIRE(reason==NFSK_CHECK_DIRTY);
  if(mode==2)REQUIRE(reason==NFSK_CHECK_HIBERNATED);
  REQUIRE(d.writes==0 && memcmp(before,d.bytes,d.size)==0);
  printf("真实桥预检通过：%s rc=%d reason=%d 写回调=0 内容不变\n",names[mode],rc,reason);
 }
 free(d.bytes);free(before);free(original);return 0;
}
