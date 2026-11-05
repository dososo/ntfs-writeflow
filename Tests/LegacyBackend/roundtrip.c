/* GPL-2.0：真实普通NTFS镜像上的FUSE回调回归，不执行系统挂载。 */
#define FUSE_USE_VERSION 26
#include "legacy_volume.h"
#include "ntfs_fskit.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int count;
#define CHECK(x) do { count++; if (!(x)) { fprintf(stderr,"失败：%s，第%d行，errno=%d\n",#x,__LINE__,errno); return 1; } } while (0)
static int listed;
static int fill(void *p, const char *name, const struct stat *s, off_t next) {
    (void)p; (void)s; (void)next;
    if (!strcmp(name,"保存.bin")) listed++;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int readonly = !strcmp(argv[1],"只读");
    int fd = open(argv[2],(readonly?O_RDONLY:O_RDWR)|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    CHECK(fd >= 0 && fstat(fd,&st)==0 && S_ISREG(st.st_mode));
    CHECK(wf_legacy_start(fd,(uint64_t)st.st_size,readonly,getuid(),true)==0);
    const struct fuse_operations *o=wf_legacy_operations();
    struct fuse_file_info fi={.flags=O_RDWR}, second={.flags=O_RDWR};
    char data[8193],got[8193]; for (size_t i=0;i<sizeof(data);i++) data[i]=(char)(i%251);
    if (!readonly) {
        CHECK(o->mkdir("/中文目录",0755)==0);
        CHECK(o->create("/中文目录/保存.bin",0644,&fi)==0);
        CHECK(o->write(NULL,data,sizeof(data),0,&fi)==sizeof(data));
        CHECK(o->read(NULL,got,sizeof(got),0,&fi)==sizeof(got) && !memcmp(got,data,sizeof(data)));
        CHECK(o->open("/中文目录/保存.bin",&second)==0);
        CHECK(o->release(NULL,&fi)==0);
        CHECK(o->read(NULL,got,sizeof(got),0,&second)==sizeof(got));
        CHECK(o->ftruncate(NULL,7000,&second)==0);
        CHECK(o->fsync(NULL,0,&second)==0);
        CHECK(o->release(NULL,&second)==0);
        CHECK(o->rename("/中文目录/保存.bin","/中文目录/临时.bin")==0);
        CHECK(o->create("/中文目录/保存.bin",0644,&fi)==0);
        CHECK(o->release(NULL,&fi)==0);
        CHECK(o->rename("/中文目录/临时.bin","/中文目录/保存.bin")==0);
        CHECK(o->open("/中文目录/保存.bin",&second)==0);
        CHECK(o->read(NULL,got,sizeof(got),0,&second)==7000 && !memcmp(got,data,7000));
        CHECK(o->release(NULL,&second)==0);
        CHECK(o->create("/已打开删除.bin",0644,&fi)==0);
        CHECK(o->write(NULL,"保留",6,0,&fi)==6);
        CHECK(o->unlink("/已打开删除.bin")==0);
        CHECK(o->read(NULL,got,6,0,&fi)==6 && !memcmp(got,"保留",6));
        CHECK(o->release(NULL,&fi)==0);
        CHECK(o->setxattr("/中文目录/保存.bin","user.writeflow","abc",3,0,0)==0);
        CHECK(o->getxattr("/中文目录/保存.bin","user.writeflow",got,sizeof(got),0)==3 && !memcmp(got,"abc",3));
        CHECK(o->removexattr("/中文目录/保存.bin","user.writeflow")==0);
        CHECK(o->symlink("保存.bin","/中文目录/链接")==0);
        CHECK(o->readlink("/中文目录/链接",got,sizeof(got))==0 && !strcmp(got,"保存.bin"));
        CHECK(o->link("/中文目录/保存.bin","/中文目录/硬链接")==0);
        CHECK(o->unlink("/中文目录/硬链接")==0);
        struct timespec times[2]={{1700000000,0},{1700000001,123}};
        CHECK(o->utimens("/中文目录/保存.bin",times)==0);
        CHECK(o->chmod("/中文目录/保存.bin",0600)==-ENOTSUP);
        struct fuse_file_info append={.flags=O_WRONLY|O_APPEND};
        CHECK(o->create("/追加.bin",0644,&append)==0);
        CHECK(o->write(NULL,"a",1,0,&append)==1);
        CHECK(o->write(NULL,"b",1,0,&append)==1);
        CHECK(o->release(NULL,&append)==0);
        append.flags=O_RDONLY;
        CHECK(o->open("/追加.bin",&append)==0);
        CHECK(o->read(NULL,got,2,0,&append)==2 && !memcmp(got,"ab",2));
        CHECK(o->release(NULL,&append)==0);
        CHECK(o->unlink("/追加.bin")==0);
        CHECK(o->fsyncdir("/中文目录",0,NULL)==0);
        char longname[730];longname[0]='/';
        for(int i=0;i<240;i++)memcpy(longname+1+i*3,"长",3);
        longname[721]=0;
        CHECK(o->create(longname,0644,&fi)==0);
        CHECK(o->write(NULL,"x",1,0,&fi)==1);
        CHECK(o->release(NULL,&fi)==0);
        CHECK(o->getattr(longname,&st)==0 && st.st_size==1);
        CHECK(o->unlink(longname)==0);
        char excessive[258];excessive[0]='/';memset(excessive+1,'a',256);excessive[257]=0;
        CHECK(o->create(excessive,0644,&fi)<0);
    } else {
        CHECK(o->create("/不能创建",0644,&fi)==-EROFS);
        CHECK(o->mkdir("/不能创建",0755)==-EROFS);
        CHECK(o->unlink("/中文目录/保存.bin")==-EROFS);
        CHECK(o->rename("/中文目录/保存.bin","/错误")==-EROFS);
        CHECK(o->open("/中文目录/保存.bin",&fi)==-EROFS);
        fi.flags=O_RDONLY;
        CHECK(o->open("/中文目录/保存.bin",&fi)==0);
        CHECK(o->read(NULL,got,sizeof(got),0,&fi)==7000 && !memcmp(got,data,7000));
        CHECK(o->write(NULL,"x",1,0,&fi)==-EROFS);
        CHECK(o->ftruncate(NULL,1,&fi)==-EROFS);
        CHECK(o->release(NULL,&fi)==0);
    }
    CHECK(o->readdir("/中文目录",NULL,fill,0,NULL)==0 && listed==1);
    CHECK(o->getattr("/中文目录/保存.bin",&st)==0 && st.st_size==7000);
    CHECK(o->getattr("/../错",&st)==-EINVAL);
    CHECK(o->getattr("/不存在/子项",&st)==-ENOENT);
    CHECK(o->write(NULL,"x",1,-1,&fi)==(readonly?-EROFS:-EBADF));
    CHECK(wf_legacy_finish()==0);
    CHECK(close(fd)==0);
    printf("通过：%d项%s真实NTFS镜像FUSE回调检查；没有挂载系统卷。\n",count,readonly?"只读":"读写");
    return 0;
}
