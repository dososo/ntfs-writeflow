/* GPL-2.0：只在普通用户新文件中验证锁元数据与父退出继承，不访问root命名空间。 */
#include "legacy_volume.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

static int count;
#define CHECK(x) do {count++;if(!(x)){fprintf(stderr,"失败：%s 第%d行 errno=%d\n",#x,__LINE__,errno);return 1;}}while(0)
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    if(!strcmp(argv[1],"持有")) {
        int lock=wf_legacy_hold_lease(STDOUT_FILENO,getuid(),argv[2]);if(lock<0)return 1;
        close(STDOUT_FILENO);fputs("已持锁\n",stderr);fflush(stderr);
        char byte;while(read(STDIN_FILENO,&byte,1)>0){}
        close(lock);return 0;
    }
    int fd=open(argv[2],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);CHECK(fd>=0);
    int lock=wf_legacy_hold_lease(fd,getuid(),argv[2]);CHECK(lock>=3);
    CHECK(fcntl(lock,F_GETFD)&FD_CLOEXEC);CHECK(fcntl(fd,F_GETFD)&FD_CLOEXEC);
    int contender=open(argv[2],O_RDWR|O_CLOEXEC);CHECK(contender>=0);
    CHECK(wf_legacy_hold_lease(contender,getuid(),argv[2])==-EWOULDBLOCK);CHECK(close(contender)==0);
    CHECK(wf_legacy_hold_lease(fd,0,argv[2])==-EPERM);
    CHECK(wf_legacy_hold_lease(fd,getuid(),"/private/tmp/不匹配")<0);
    CHECK(fchmod(fd,0644)==0);CHECK(wf_legacy_hold_lease(fd,getuid(),argv[2])==-EPERM);CHECK(fchmod(fd,0600)==0);
    char other[4096];if(snprintf(other,sizeof(other),"%s.link",argv[2])>=(int)sizeof(other))return 2;
    CHECK(link(argv[2],other)==0);CHECK(wf_legacy_hold_lease(fd,getuid(),argv[2])==-EPERM);CHECK(unlink(other)==0);
    /* 即使只读ALLOW条目，也不满足全局租约的空ACL要求。 */
    acl_t acl=acl_init(1);CHECK(acl!=NULL);acl_entry_t entry;CHECK(acl_create_entry(&acl,&entry)==0);
    CHECK(acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)==0);
    unsigned char qualifier[16]={0};CHECK(acl_set_qualifier(entry,qualifier)==0);
    acl_permset_t permissions;CHECK(acl_get_permset(entry,&permissions)==0);CHECK(acl_add_perm(permissions,ACL_READ_DATA)==0);
    CHECK(acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED)==0);acl_free(acl);
    CHECK(wf_legacy_hold_lease(fd,getuid(),argv[2])==-EPERM);
    acl=acl_init(0);CHECK(acl!=NULL);CHECK(acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED)==0);acl_free(acl);
    CHECK(close(lock)==0);CHECK(fcntl(fd,F_GETFD)>=0);CHECK(close(fd)==0);
    CHECK(wf_legacy_hold_lease(fd,getuid(),argv[2])==-EBADF);
    int pipefd[2];CHECK(pipe(pipefd)==0);CHECK(wf_legacy_hold_lease(pipefd[0],getuid(),argv[2])==-EPERM);
    close(pipefd[0]);close(pipefd[1]);
    printf("通过：%d项租约FD类型、路径、所有者、权限、ACL、单链接和持有副本检查。\n",count);return 0;
}
