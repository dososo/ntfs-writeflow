/* GPL-2.0：单线程FUSE 2.6操作表，所有文件语义由既有nfsk桥执行。 */
#include "legacy_volume.h"
#include "ntfs_fskit.h"
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>
#include <unistd.h>

#define LEAF_CAPACITY 1024

static ntfs_fskit_volume *volume;
static void *backend;
static bool readonly_volume;
static uid_t owner;
static gid_t group;
static int final_error;
struct opened { uint64_t id, ino; int flags; struct opened *next; };
static struct opened *handles;
static uint64_t next_handle;

int wf_legacy_start(int fd, uint64_t bytes, bool readonly, uid_t uid, bool allow_file) {
    if (volume || backend) return -EBUSY;
    int error=0,reason=0;
    int result=0;
    if (!readonly) {
        backend=wf_legacy_backend(fd,bytes,false,allow_file,&error);
        if (!backend) return -error;
        result=nfsk_quick_check(backend,&reason);
        nfsk_backend_free(backend); backend=NULL;
        if (result) return result;
    }
    backend=wf_legacy_backend(fd,bytes,!readonly,allow_file,&error);
    if (!backend) return -error;
    volume=nfsk_mount(backend,readonly,&error);
    if (!volume) { nfsk_backend_free(backend); backend=NULL; return -(error?error:EIO); }
    nfsk_statfs_t stats;
    result=nfsk_statfs(volume,&stats);
    if (result || (stats.read_only!=0)!=readonly) {
        (void)nfsk_umount(volume); volume=NULL; nfsk_backend_free(backend); backend=NULL;
        return result?result:-EROFS;
    }
    readonly_volume=readonly;owner=uid; struct passwd *pw=getpwuid(uid);group=pw?pw->pw_gid:uid;
    final_error=0;next_handle=1;return 0;
}

int wf_legacy_finish(void) {
    if (!volume) return final_error;
    while (handles) {
        struct opened *h=handles; handles=h->next;
        bool remains=false;for (struct opened *p=handles;p;p=p->next) if(p->ino==h->ino) remains=true;
        if (!remains) { int e=nfsk_close_item(volume,h->ino);if(e&&!final_error)final_error=e; }
        free(h);
    }
    int error=nfsk_umount(volume);volume=NULL;
    if(error&&!final_error)final_error=error;
    nfsk_backend_free(backend);backend=NULL;
    return final_error;
}

static int lookup(const char *path, uint64_t *ino) {
    if (!volume) return -ENXIO;
    if (!path || path[0]!='/' || strnlen(path,PATH_MAX)>=PATH_MAX) return -EINVAL;
    char copy[PATH_MAX];strcpy(copy,path);uint64_t current=NFSK_ROOT_INO;char *save=NULL;
    for(char *part=strtok_r(copy,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
        if (!strcmp(part,".")||!strcmp(part,".."))return -EINVAL;
        int error=0;current=nfsk_lookup(volume,current,part,&error);
        if(!current)return -(error?error:ENOENT);
    }
    *ino=current;return 0;
}
static int parent(const char *path, uint64_t *ino, char name[LEAF_CAPACITY]) {
    if (!path || path[0]!='/' || strnlen(path,PATH_MAX)>=PATH_MAX)return -EINVAL;
    char copy[PATH_MAX];strcpy(copy,path);char *last=strrchr(copy,'/');
    if(!last || !last[1] || strlen(last+1)>=LEAF_CAPACITY || !strcmp(last+1,".") || !strcmp(last+1,".."))return -EINVAL;
    strcpy(name,last+1);if(last==copy)copy[1]=0;else *last=0;
    return lookup(copy,ino);
}
static struct opened *opened(struct fuse_file_info *fi) {
    if(!fi || !fi->fh)return NULL;
    for(struct opened *p=handles;p;p=p->next)if(p->id==fi->fh)return p;
    return NULL;
}
static int add_handle(uint64_t ino, struct fuse_file_info *fi) {
    if(!fi)return -EINVAL;
    struct opened *h=calloc(1,sizeof(*h));if(!h)return -ENOMEM;
    int error=nfsk_open_item(volume,ino);if(error){free(h);return error;}
    if(!next_handle){free(h);return -EMFILE;}
    h->id=next_handle++;h->ino=ino;h->flags=fi->flags;h->next=handles;handles=h;fi->fh=h->id;return 0;
}
static void attributes(const nfsk_attr_t *a, struct stat *st) {
    memset(st,0,sizeof(*st));st->st_ino=a->ino;st->st_uid=owner;st->st_gid=group;
    mode_t type=a->type==NFSK_TYPE_DIR?S_IFDIR:a->type==NFSK_TYPE_SYMLINK?S_IFLNK:S_IFREG;
    st->st_mode=type|(a->mode&0777);st->st_nlink=a->nlink;st->st_size=a->size;
    st->st_blocks=(blkcnt_t)((a->alloc_size+511)/512);st->st_blksize=4096;st->st_flags=a->flags;
    st->st_mtimespec=(struct timespec){a->mtime_sec,a->mtime_nsec};
    st->st_atimespec=(struct timespec){a->atime_sec,a->atime_nsec};
    st->st_ctimespec=(struct timespec){a->ctime_sec,a->ctime_nsec};
    st->st_birthtimespec=(struct timespec){a->btime_sec,a->btime_nsec};
}
static int getattr_cb(const char *path, struct stat *st) {
    uint64_t ino;int error=lookup(path,&ino);if(error)return error;
    nfsk_attr_t a;error=nfsk_getattr(volume,ino,&a);if(!error)attributes(&a,st);return error;
}
static int fgetattr_cb(const char *path, struct stat *st, struct fuse_file_info *fi) {
    (void)path;struct opened *h=opened(fi);if(!h)return -EBADF;
    nfsk_attr_t a;int error=nfsk_getattr(volume,h->ino,&a);if(!error)attributes(&a,st);return error;
}
static int release_cb(const char *path,struct fuse_file_info *fi);
static int open_cb(const char *path, struct fuse_file_info *fi) {
    if(!fi)return -EINVAL;
    if(readonly_volume && ((fi->flags&O_ACCMODE)!=O_RDONLY || (fi->flags&O_TRUNC)))return -EROFS;
    uint64_t ino;int error=lookup(path,&ino);if(error)return error;
    nfsk_attr_t a;error=nfsk_getattr(volume,ino,&a);if(error)return error;
    if(a.type!=NFSK_TYPE_FILE)return a.type==NFSK_TYPE_DIR?-EISDIR:-EINVAL;
    error=add_handle(ino,fi);if(error)return error;
    if(fi->flags&O_TRUNC){error=nfsk_truncate(volume,ino,0);if(error){(void)release_cb(path,fi);return error;}}
    return 0;
}
static int release_cb(const char *path, struct fuse_file_info *fi) {
    (void)path;struct opened *h=opened(fi);if(!h)return -EBADF;
    struct opened **p=&handles;while(*p!=h)p=&(*p)->next;*p=h->next;
    bool remains=false;for(struct opened *p=handles;p;p=p->next)if(p->ino==h->ino)remains=true;
    int error=remains?0:nfsk_close_item(volume,h->ino);if(error&&!final_error)final_error=error;
    fi->fh=0;free(h);return error;
}
static int create_cb(const char *path, mode_t mode, struct fuse_file_info *fi) {
    (void)mode;if(readonly_volume)return -EROFS;
    uint64_t dir;char name[LEAF_CAPACITY];int error=parent(path,&dir,name);if(error)return error;
    uint64_t ino=nfsk_create(volume,dir,name,NFSK_TYPE_FILE,&error);
    return ino?add_handle(ino,fi):-(error?error:EIO);
}
static int mkdir_cb(const char *path, mode_t mode) {
    (void)mode;if(readonly_volume)return -EROFS;
    uint64_t dir;char name[LEAF_CAPACITY];int error=parent(path,&dir,name);if(error)return error;
    return nfsk_create(volume,dir,name,NFSK_TYPE_DIR,&error)?0:-(error?error:EIO);
}
static int read_cb(const char *path, char *buffer, size_t length, off_t offset, struct fuse_file_info *fi) {
    (void)path;struct opened *h=opened(fi);if(!h)return -EBADF;
    if((h->flags&O_ACCMODE)==O_WRONLY)return -EBADF;
    if(length>INT_MAX || offset<0)return -EINVAL;
    int error=0;int64_t got=nfsk_read(volume,h->ino,offset,buffer,length,&error);
    return got<0?-(error?error:EIO):(int)got;
}
static int write_cb(const char *path,const char *buffer,size_t length,off_t offset,struct fuse_file_info *fi) {
    (void)path;if(readonly_volume)return -EROFS;
    struct opened *h=opened(fi);if(!h || (h->flags&O_ACCMODE)==O_RDONLY)return -EBADF;
    if(length>INT_MAX || offset<0)return -EINVAL;
    if(h->flags&O_APPEND) {
        nfsk_attr_t attr;int error=nfsk_getattr(volume,h->ino,&attr);if(error)return error;
        if(attr.size>INT64_MAX)return -EOVERFLOW;offset=(off_t)attr.size;
    }
    int error=0;int64_t done=nfsk_write(volume,h->ino,offset,buffer,length,&error);
    return done<0?-(error?error:EIO):(int)done;
}
static int truncate_cb(const char *path,off_t size) {
    if(readonly_volume)return -EROFS;if(size<0)return -EINVAL;
    uint64_t ino;int error=lookup(path,&ino);return error?error:nfsk_truncate(volume,ino,size);
}
static int ftruncate_cb(const char *path,off_t size,struct fuse_file_info *fi) {
    (void)path;if(readonly_volume)return -EROFS;
    struct opened *h=opened(fi);if(!h || (h->flags&O_ACCMODE)==O_RDONLY)return -EBADF;
    return size<0?-EINVAL:nfsk_truncate(volume,h->ino,size);
}
static int sync_cb(const char *path,int data,struct fuse_file_info *fi) {
    (void)path;(void)data;if(fi && !opened(fi))return -EBADF;
    int error=nfsk_sync(volume);if(error&&!final_error)final_error=error;return error;
}
static int flush_cb(const char *path,struct fuse_file_info *fi) { return sync_cb(path,0,fi); }
static int dirsync_cb(const char *path,int data,struct fuse_file_info *fi) {
    (void)path;(void)data;(void)fi;return sync_cb(NULL,0,NULL);
}
static int remove_path(const char *path,bool directory) {
    if(readonly_volume)return -EROFS;
    uint64_t ino;int error=lookup(path,&ino);if(error)return error;
    nfsk_attr_t a;error=nfsk_getattr(volume,ino,&a);if(error)return error;
    if((a.type==NFSK_TYPE_DIR)!=directory)return directory?-ENOTDIR:-EISDIR;
    uint64_t dir;char name[LEAF_CAPACITY];error=parent(path,&dir,name);
    return error?error:nfsk_remove(volume,dir,name);
}
static int unlink_cb(const char *path) { return remove_path(path,false); }
static int rmdir_cb(const char *path) { return remove_path(path,true); }
static int rename_cb(const char *from,const char *to) {
    if(readonly_volume)return -EROFS;
    uint64_t a,b;char na[LEAF_CAPACITY],nb[LEAF_CAPACITY];int e=parent(from,&a,na);if(e)return e;e=parent(to,&b,nb);
    return e?e:nfsk_rename(volume,a,na,b,nb);
}
static int link_cb(const char *from,const char *to) {
    if(readonly_volume)return -EROFS;
    uint64_t ino,dir;char name[LEAF_CAPACITY];int e=lookup(from,&ino);if(e)return e;e=parent(to,&dir,name);
    return e?e:nfsk_link(volume,ino,dir,name,&e);
}
static int symlink_cb(const char *target,const char *path) {
    if(readonly_volume)return -EROFS;
    uint64_t dir;char name[LEAF_CAPACITY];int e=parent(path,&dir,name);if(e)return e;
    return nfsk_symlink(volume,dir,name,target,&e)?0:-(e?e:EIO);
}
static int readlink_cb(const char *path,char *buffer,size_t length) {
    uint64_t ino;int e=lookup(path,&ino);return e?e:nfsk_readlink(volume,ino,buffer,length);
}
struct listing { void *buffer; fuse_fill_dir_t fill; };
static int entry(void *opaque,const char *name,uint64_t ino,uint32_t type,int64_t cookie) {
    struct listing *l=opaque;struct stat st={0};st.st_ino=ino;st.st_mode=type==NFSK_TYPE_DIR?S_IFDIR:type==NFSK_TYPE_SYMLINK?S_IFLNK:S_IFREG;
    return l->fill(l->buffer,name,&st,(off_t)cookie+2);
}
static int readdir_cb(const char *path,void *buffer,fuse_fill_dir_t fill,off_t offset,struct fuse_file_info *fi) {
    (void)fi;if(offset<0)return -EINVAL;uint64_t ino;int e=lookup(path,&ino);if(e)return e;
    if(offset==0 && fill(buffer,".",NULL,1))return 0;
    if(offset<=1 && fill(buffer,"..",NULL,2))return 0;
    struct listing list={buffer,fill};return nfsk_readdir(volume,ino,offset>2?offset-2:0,&list,entry);
}
static int statfs_cb(const char *path,struct statvfs *st) {
    (void)path;nfsk_statfs_t a;int e=nfsk_statfs(volume,&a);if(e)return e;
    memset(st,0,sizeof(*st));st->f_bsize=a.cluster_size;st->f_frsize=a.cluster_size;st->f_blocks=a.total_clusters;
    st->f_bfree=a.free_clusters;st->f_bavail=a.free_clusters;st->f_files=a.total_files;st->f_ffree=a.free_files;
    st->f_namemax=255;st->f_flag=readonly_volume?ST_RDONLY:0;return 0;
}
static int setxattr_cb(const char *path,const char *name,const char *value,size_t size,int flags,uint32_t position) {
    if(readonly_volume)return -EROFS;if(position)return -ENOTSUP;
    if(flags&~(XATTR_CREATE|XATTR_REPLACE) || (flags&(XATTR_CREATE|XATTR_REPLACE))==(XATTR_CREATE|XATTR_REPLACE))return -EINVAL;
    uint64_t ino;int e=lookup(path,&ino);if(e)return e;
    return nfsk_setxattr(volume,ino,name,value,size,flags&XATTR_CREATE?NFSK_XATTR_CREATE:flags&XATTR_REPLACE?NFSK_XATTR_REPLACE:NFSK_XATTR_SET);
}
static int getxattr_cb(const char *path,const char *name,char *value,size_t size,uint32_t position) {
    if(position)return -ENOTSUP;uint64_t ino;int e=lookup(path,&ino);if(e)return e;
    int64_t n=nfsk_getxattr(volume,ino,name,value,size);return n>INT_MAX?-EOVERFLOW:(int)n;
}
static int listxattr_cb(const char *path,char *value,size_t size) {
    uint64_t ino;int e=lookup(path,&ino);if(e)return e;int64_t n=nfsk_listxattr(volume,ino,value,size);return n>INT_MAX?-EOVERFLOW:(int)n;
}
static int removexattr_cb(const char *path,const char *name) {
    if(readonly_volume)return -EROFS;uint64_t ino;int e=lookup(path,&ino);return e?e:nfsk_setxattr(volume,ino,name,NULL,0,NFSK_XATTR_DELETE);
}
static int times_cb(const char *path,const struct timespec times[2]) {
    if(readonly_volume)return -EROFS;if(!times)return -EINVAL;
    uint64_t ino;int e=lookup(path,&ino);if(e)return e;nfsk_attr_t a;e=nfsk_getattr(volume,ino,&a);if(e)return e;
    struct timespec now;if(clock_gettime(CLOCK_REALTIME,&now))return -errno;
    nfsk_metadata_t metadata={0};
    for(int i=0;i<2;i++) {
        struct timespec t=times[i];if(t.tv_nsec==UTIME_OMIT)continue;if(t.tv_nsec==UTIME_NOW)t=now;
        if(t.tv_nsec<0 || t.tv_nsec>=1000000000)return -EINVAL;
        if(i==0){metadata.valid|=NFSK_SET_ATIME;metadata.atime_sec=t.tv_sec;metadata.atime_nsec=t.tv_nsec;}
        else {metadata.valid|=NFSK_SET_MTIME;metadata.mtime_sec=t.tv_sec;metadata.mtime_nsec=t.tv_nsec;}
    }
    return metadata.valid?nfsk_set_metadata(volume,ino,&metadata):0;
}
static int chmod_cb(const char *path,mode_t mode) { (void)path;(void)mode;return readonly_volume?-EROFS:-ENOTSUP; }
static int chown_cb(const char *path,uid_t uid,gid_t gid) { (void)path;(void)uid;(void)gid;return readonly_volume?-EROFS:-ENOTSUP; }
static int access_cb(const char *path,int mask) {
    if(readonly_volume&&(mask&W_OK))return -EROFS;uint64_t ino;return lookup(path,&ino);
}
static void destroy_cb(void *data) { (void)data;(void)wf_legacy_finish(); }

static const struct fuse_operations operations={
    .getattr=getattr_cb,.fgetattr=fgetattr_cb,.readlink=readlink_cb,.mkdir=mkdir_cb,.unlink=unlink_cb,.rmdir=rmdir_cb,
    .symlink=symlink_cb,.rename=rename_cb,.link=link_cb,.chmod=chmod_cb,.chown=chown_cb,.truncate=truncate_cb,
    .open=open_cb,.read=read_cb,.write=write_cb,.statfs=statfs_cb,.flush=flush_cb,.release=release_cb,.fsync=sync_cb,
    .setxattr=setxattr_cb,.getxattr=getxattr_cb,.listxattr=listxattr_cb,.removexattr=removexattr_cb,.readdir=readdir_cb,
    .access=access_cb,.create=create_cb,.ftruncate=ftruncate_cb,.utimens=times_cb,.destroy=destroy_cb,.fsyncdir=dirsync_cb,
    .flag_nullpath_ok=1,.flag_nopath=1,.flag_utime_omit_ok=1
};
const struct fuse_operations *wf_legacy_operations(void) { return &operations; }
