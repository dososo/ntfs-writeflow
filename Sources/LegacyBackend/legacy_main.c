/* GPL-2.0：受限兼容挂载子程序；不安装运行时，不改变系统安全设置。 */
#include "legacy_volume.h"
#include "legacy_receipt.h"
#include "ntfs_fskit.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>

static int number(const char *text,uint64_t maximum,uint64_t *out) {
    if (!text || !*text || (text[0]=='0' && text[1]))return 0;
    for(const char *p=text;*p;p++)if(*p<'0'||*p>'9')return 0;
    errno=0;char *end;unsigned long long value=strtoull(text,&end,10);
    if(errno || *end || value>maximum)return 0;*out=value;return 1;
}
static int safe_acl(int fd) {
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    int valid=1;acl_entry_t entry;int next=ACL_FIRST_ENTRY;
    while(acl_get_entry(acl,next,&entry)==0) {
        next=ACL_NEXT_ENTRY;acl_tag_t tag;acl_permset_t permissions;
        if(acl_get_tag_type(entry,&tag) || acl_get_permset(entry,&permissions)){valid=0;break;}
        if(tag!=ACL_EXTENDED_ALLOW)continue;
        acl_perm_t forbidden[]={ACL_WRITE_DATA,ACL_APPEND_DATA,ACL_DELETE,ACL_DELETE_CHILD,ACL_WRITE_ATTRIBUTES,ACL_WRITE_EXTATTRIBUTES,ACL_WRITE_SECURITY,ACL_CHANGE_OWNER};
        for(size_t i=0;i<sizeof(forbidden)/sizeof(forbidden[0]);i++)if(acl_get_perm_np(permissions,forbidden[i])!=0)valid=0;
    }
    acl_free(acl);return valid;
}
static int protected_path(const char *path,bool directory) {
    if(!path || path[0]!='/' || strnlen(path,PATH_MAX)>=PATH_MAX)return 0;
    char copy[PATH_MAX];strcpy(copy,path);char *save=NULL;int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(fd<0)return 0;
    for(char *part=strtok_r(copy,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
        if(!strcmp(part,".")||!strcmp(part,"..")){close(fd);return 0;}
        bool last=!save || !*save;
        int child=openat(fd,part,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|((!last||directory)?O_DIRECTORY:0));
        close(fd);fd=child;if(fd<0)return 0;
        struct stat st;
        if(fstat(fd,&st)||st.st_uid!=0||(st.st_mode&0022)||(!last&&!S_ISDIR(st.st_mode))||!safe_acl(fd)) {close(fd);return 0;}
        if(last && (directory?!S_ISDIR(st.st_mode):!S_ISREG(st.st_mode))){close(fd);return 0;}
    }
    close(fd);return 1;
}
static int mount_token(const char *path,uid_t uid,char token[37]) {
    char prefix[160];snprintf(prefix,sizeof(prefix),"/private/var/db/com.blteam.ntfsworkbench.mounts/%u/",uid);
    size_t length=strlen(prefix);
    if(strncmp(path,prefix,length) || strlen(path+length)!=43 || strcmp(path+length+36,"/volume"))return 0;
    memcpy(token,path+length,36);token[36]=0;uuid_t parsed;char canonical[37];
    if(uuid_parse(token,parsed))return 0;uuid_unparse_upper(parsed,canonical);return !strcmp(token,canonical);
}

int main(int argc,char **argv) {
    if(argc!=15 || strcmp(argv[1],"--mount") || strcmp(argv[3],"--uid") || strcmp(argv[5],"--bytes") || strcmp(argv[7],"--readonly") || strcmp(argv[9],"--runtime") || strcmp(argv[11],"--device") || strcmp(argv[13],"--media-id")) {
        fprintf(stderr,"兼容挂载仅接受受限管理员服务提供的固定参数。\n");return 64;
    }
    uint64_t uid,bytes,readonly,whole;char token[37];
    if(!number(argv[4],UINT32_MAX-1,&uid)||uid<501||!number(argv[6],INT64_MAX,&bytes)||!bytes||
       !number(argv[8],1,&readonly)||!number(argv[14],UINT64_MAX,&whole)||!whole||!mount_token(argv[2],(uid_t)uid,token)) {
        fprintf(stderr,"兼容挂载参数或凭据路径无效。\n");return 64;
    }
    if(geteuid()!=0){fprintf(stderr,"兼容挂载须由已授权管理员服务启动。\n");return 77;}
    char lease_path[192];
    snprintf(lease_path,sizeof(lease_path),"/private/var/db/com.blteam.ntfsworkbench.mounts/media-leases/%llu.lock",(unsigned long long)whole);
    if(!protected_path(lease_path,false)) {
        fprintf(stderr,"介质租约路径未受系统保护。\n");return 77;
    }
    int lease=wf_legacy_hold_lease(STDOUT_FILENO,0,lease_path);
    if(lease<0){fprintf(stderr,"介质租约无效或已被其他挂载进程持有（%d）。\n",-lease);return 77;}
    /* stdout不再承载租约本体，防止外部库缓冲输出污染持久回执。 */
    int quiet=open("/dev/null",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
    if(quiet<0 || dup2(quiet,STDOUT_FILENO)<0){if(quiet>=0)close(quiet);return 77;}
    close(quiet);
    struct stat device;
    if(fstat(STDIN_FILENO,&device)||!S_ISCHR(device.st_mode)||!protected_path(argv[2],true)) {
        fprintf(stderr,"设备句柄或系统保护挂载路径核验失败。\n");return 77;
    }
    int device_flags=fcntl(STDIN_FILENO,F_GETFD);
    if(device_flags<0 || fcntl(STDIN_FILENO,F_SETFD,device_flags|FD_CLOEXEC)) {
        fprintf(stderr,"无法隔离设备句柄继承。\n");return 77;
    }
    const char *id=argv[12];char options[320];
    if(wf_legacy_mount_options(options,sizeof(options),readonly!=0,id))return 64;
    char node[PATH_MAX];
    if(!devname_r(device.st_rdev,S_IFCHR,node,sizeof(node)) || node[0]!='r' || strcmp(node+1,id)) {
        fprintf(stderr,"传入设备句柄与来源标识不一致。\n");return 77;
    }
    char canonical[PATH_MAX],expected[PATH_MAX];
    if(strlen(argv[2])>PATH_MAX-64)return 64;
    strcpy(expected,argv[2]);expected[strlen(expected)-7]=0;
    strcat(expected,"/runtime/libfuse.2.dylib");
    if(strcmp(argv[10],expected)||!realpath(argv[10],canonical)||strcmp(canonical,argv[10])||
       !protected_path(canonical,false)||!protected_path("/Library/Filesystems/macfuse.fs",true)) {
        fprintf(stderr,"未找到受系统目录保护的macFUSE运行时；请按官方说明自行安装。\n");return 78;
    }
    int flags=fcntl(STDIN_FILENO,F_GETFL);
    if(flags<0 || (flags&O_ACCMODE)!=(readonly?O_RDONLY:O_RDWR) || (flags&O_EVTONLY)) {
        fprintf(stderr,"设备句柄访问模式不匹配。\n");return 77;
    }
    int error=0;
    void *checked=wf_legacy_backend(STDIN_FILENO,bytes,false,false,&error);
    if(!checked){fprintf(stderr,"设备容量或只读访问核验失败（%d）。\n",error);return 77;}
    nfsk_backend_free(checked);
    /* 所有上下文核验均先于加载外部运行时；helper还须独立检查其正式签名。 */
    void *runtime=dlopen(canonical,RTLD_NOW|RTLD_LOCAL);
    if(!runtime){fprintf(stderr,"macFUSE运行时无法加载：%s\n",dlerror());return 78;}
    typedef int (*main_fn)(int,char **,const struct fuse_operations *,size_t,void *);
    main_fn run=(main_fn)dlsym(runtime,"fuse_main_real");
    if(!run){fprintf(stderr,"macFUSE运行时缺少FUSE2.6入口。\n");dlclose(runtime);return 78;}
    if(wf_legacy_write_receipt(lease,(uint32_t)uid,whole,token,0,false)) {
        fprintf(stderr,"无法持久化进行中的媒体回执，未开启数据写入。\n");dlclose(runtime);return 74;
    }
    error=wf_legacy_start(STDIN_FILENO,bytes,readonly!=0,(uid_t)uid,false);
    if(error) {
        fprintf(stderr,"兼容挂载只读预检或资源打开失败（%d）。\n",-error);
        (void)wf_legacy_write_receipt(lease,(uint32_t)uid,whole,token,74,true);
        dlclose(runtime);return 74;
    }
    char *args[]={"NTFSWriteFlowLegacy","-f","-s","-o",options,argv[2],NULL};
    int result=run(6,args,wf_legacy_operations(),sizeof(struct fuse_operations),NULL);
    error=wf_legacy_finish();
    if(error)fprintf(stderr,"兼容后端同步或关闭失败（%d），不能当作数据已完整落盘。\n",-error);
    int status=result==0 && error==0?0:result>0 && result<=255?result:74;
    if(wf_legacy_write_receipt(lease,(uint32_t)uid,whole,token,status,true)) {
        fprintf(stderr,"兼容后端未提交干净收尾回执。\n");status=74;
    }
    dlclose(runtime);close(lease);return status;
}
