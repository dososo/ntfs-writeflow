/* GPL-2.0：全局介质flock随dup及进程继承；保留到实际文件系统进程结束。 */
#include "legacy_volume.h"
#include "legacy_receipt.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>

static int empty_acl(int descriptor) {
    acl_t actual=acl_get_fd_np(descriptor,ACL_TYPE_EXTENDED);
    if(!actual) {
        if(errno!=ENOENT)return 0;
        filesec_t security=filesec_init();if(!security)return 0;
        struct stat st;int present=-1;
        int valid=fstatx_np(descriptor,&st,security)==0 &&
            filesec_query_property(security,FILESEC_ACL,&present)==0 && present==0;
        filesec_free(security);return valid;
    }
    acl_t expected=acl_init(0);
    char *first=expected?acl_to_text(expected,NULL):NULL;
    char *second=acl_to_text(actual,NULL);
    int valid=first && second && strcmp(first,second)==0;
    if(first)acl_free(first);if(second)acl_free(second);
    if(expected)acl_free(expected);
    acl_free(actual);return valid;
}

int wf_legacy_hold_lease(int descriptor,uid_t owner,const char *path) {
    struct stat st;char actual[PATH_MAX];int flags=fcntl(descriptor,F_GETFL);
    if(flags<0 || fstat(descriptor,&st))return -errno;
    if(!path || strlen(path)>=PATH_MAX || st.st_uid!=owner || !S_ISREG(st.st_mode) ||
       st.st_nlink!=1 || (st.st_mode&07777)!=0600 || (flags&O_EVTONLY) ||
       (flags&O_ACCMODE)!=O_RDWR || fcntl(descriptor,F_GETPATH,actual)<0 || strcmp(actual,path) ||
       !empty_acl(descriptor))return -EPERM;
    if(flock(descriptor,LOCK_EX|LOCK_NB))return -errno;
    int copy=fcntl(descriptor,F_DUPFD_CLOEXEC,3);
    if(copy<0)return -errno;
    int descriptor_flags=fcntl(descriptor,F_GETFD);
    if(descriptor_flags<0 || fcntl(descriptor,F_SETFD,descriptor_flags|FD_CLOEXEC)) {
        int error=errno;close(copy);return -error;
    }
    return copy;
}

static int write_bytes(const struct wf_legacy_receipt_io *io,int descriptor,const void *bytes,size_t length,off_t offset) {
    size_t done=0;
    while(done<length) {
        errno=0;
        ssize_t wrote=io->write_at(descriptor,(const char *)bytes+done,length-done,offset+(off_t)done);
        if(wrote<0 && errno==EINTR)continue;
        if(wrote<=0)return -(errno?errno:EIO);
        if((size_t)wrote>length-done)return -EIO;
        done+=(size_t)wrote;
    }
    return 0;
}

int wf_legacy_write_receipt_with_io(int descriptor,uint32_t user_id,uint64_t whole_media_id,
                                   const char *token,int status,bool complete,const struct wf_legacy_receipt_io *io) {
    if(!io || !io->write_at || !io->synchronize || !io->resize || user_id<501 || user_id==UINT32_MAX ||
       !whole_media_id || !token || strlen(token)!=36 || status<0 || status>255)return -EINVAL;
    uuid_t parsed;char canonical[37];
    if(uuid_parse(token,parsed))return -EINVAL;
    uuid_unparse_upper(parsed,canonical);
    if(strcmp(token,canonical))return -EINVAL;
    char body[256];
    int length=snprintf(body,sizeof(body),"{\"version\":1,\"userID\":%u,\"wholeMediaRegistryID\":%llu,\"token\":\"%s\",\"status\":%d}",
                        user_id,(unsigned long long)whole_media_id,token,status);
    if(length<=0 || (size_t)length>=sizeof(body))return -EINVAL;

    /* 先持久化未知标记，旧回执在任何新数据写入之前失效。 */
    const unsigned char pending=0,committed=1;
    int error=write_bytes(io,descriptor,&pending,1,0);
    if(error)return error;
    if(io->synchronize(descriptor))return -(errno?errno:EIO);
    error=write_bytes(io,descriptor,body,(size_t)length,1);
    if(error)return error;
    /* 从不截断成空文件，不产生可被误认作首次会话的空窗口。 */
    if(io->resize(descriptor,(off_t)length+1))return -(errno?errno:EIO);
    if(io->synchronize(descriptor))return -(errno?errno:EIO);
    if(!complete)return 0;

    error=write_bytes(io,descriptor,&committed,1,0);
    if(!error && io->synchronize(descriptor))error=-(errno?errno:EIO);
    if(error) {
        /* commit同步失败时尽力保持未知；底层拒绝撤销写时仍返回错误，绝不报告成功。 */
        (void)write_bytes(io,descriptor,&pending,1,0);
        (void)io->synchronize(descriptor);
        return error;
    }
    return 0;
}

int wf_legacy_write_receipt(int descriptor,uint32_t user_id,uint64_t whole_media_id,
                           const char *token,int status,bool complete) {
    static const struct wf_legacy_receipt_io io={.write_at=pwrite,.synchronize=fsync,.resize=ftruncate};
    return wf_legacy_write_receipt_with_io(descriptor,user_id,whole_media_id,token,status,complete,&io);
}
