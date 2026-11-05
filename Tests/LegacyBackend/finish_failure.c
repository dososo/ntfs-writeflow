/* GPL-2.0：子进程本地文件大小限额制造真实关闭写失败；仅测试新普通镜像。 */
#include "legacy_volume.h"
#include "legacy_receipt.h"
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc,char **argv) {
    if(argc!=4 || geteuid()==0 || (strcmp(argv[1],"正常") && strcmp(argv[1],"失败")))return 2;
    int failing=!strcmp(argv[1],"失败");
    int fd=open(argv[2],O_RDWR|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_nlink!=1)return 2;
    int receipt=open(argv[3],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    if(receipt<0 || flock(receipt,LOCK_EX|LOCK_NB))return 2;
    const char *token="11111111-2222-4333-8444-555555555555";
    if(wf_legacy_write_receipt(receipt,getuid(),UINT64_C(9876543210),token,0,false))return 1;
    if(wf_legacy_start(fd,(uint64_t)st.st_size,false,getuid(),true))return 1;
    struct fuse_file_info fi={.flags=O_RDWR};const struct fuse_operations *ops=wf_legacy_operations();
    if(ops->create("/末尾关闭故障.bin",0644,&fi) || ops->write(NULL,"原始内容",12,0,&fi)!=12)return 1;
    struct rlimit before,limited;
    if(failing) {
        if(getrlimit(RLIMIT_FSIZE,&before))return 1;
        limited=before;limited.rlim_cur=1024;
        if(signal(SIGXFSZ,SIG_IGN)==SIG_ERR || setrlimit(RLIMIT_FSIZE,&limited))return 1;
    }
    int closed=wf_legacy_finish();
    if(failing && setrlimit(RLIMIT_FSIZE,&before))return 1;
    if((failing && closed>=0) || (!failing && closed!=0))return 1;
    int status=closed?74:0;
    if(wf_legacy_write_receipt(receipt,getuid(),UINT64_C(9876543210),token,status,true))return 1;
    close(receipt);close(fd);
    printf("通过：%s对照，真实wf_legacy_finish返回%d，持久收尾status%d，子进程退出%d；未执行系统挂载。\n",failing?"末尾故障":"正常关闭",closed,status,status);
    return status;
}
