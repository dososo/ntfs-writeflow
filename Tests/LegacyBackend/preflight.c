/* GPL-2.0：脏卷写入拒绝及只读恢复，仅测试普通文件。 */
#include "legacy_volume.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc!=3)return 2;bool readonly=!strcmp(argv[1],"只读");
    int fd=open(argv[2],(readonly?O_RDONLY:O_RDWR)|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode))return 2;
    int result=wf_legacy_start(fd,st.st_size,readonly,getuid(),true);
    if(readonly){if(result||wf_legacy_finish())return 1;}
    else if(result>=0)return 1;
    if(fcntl(fd,F_GETFD)<0)return 1;close(fd);
    printf("通过：%s，未接管调用者FD。\n",readonly?"脏卷只读打开并正常关闭":"脏卷预检拒绝读写初始化");return 0;
}
