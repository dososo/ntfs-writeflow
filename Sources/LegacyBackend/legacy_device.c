/* GPL-2.0：持续持有的设备FD，禁止以可复用设备名重新打开资源。 */
#include "legacy_volume.h"
#include "ntfs_fskit.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

struct device { int fd; bool writable, raw; uint64_t bytes; uint32_t sector; };

void *wf_legacy_backend(int fd, uint64_t bytes, bool writable, bool allow_file, int *error) {
    struct stat st; uint64_t count; uint32_t sector=512;
    int flags=fcntl(fd,F_GETFL);
    int failure=EINVAL;
    if (flags<0 || fstat(fd,&st)) { failure=errno; goto fail; }
    if ((flags&O_ACCMODE)==O_WRONLY || (writable && (flags&O_ACCMODE)!=O_RDWR)) { failure=EACCES; goto fail; }
    if (!bytes || bytes>INT64_MAX || (flags&(O_EVTONLY|O_APPEND))) goto fail;
    if (S_ISREG(st.st_mode) && allow_file) {
        if (st.st_size<=0 || (uint64_t)st.st_size!=bytes) goto fail;
    } else if (S_ISCHR(st.st_mode)) {
        if (ioctl(fd,DKIOCGETBLOCKSIZE,&sector) || ioctl(fd,DKIOCGETBLOCKCOUNT,&count)) { failure=errno; goto fail; }
        if (sector<512 || sector>1048576 || (sector&(sector-1)) || count>UINT64_MAX/sector || count*sector!=bytes) goto fail;
    } else goto fail;
    int copy=fcntl(fd,F_DUPFD_CLOEXEC,3);
    if (copy<0) { failure=errno; goto fail; }
    struct device *d=calloc(1,sizeof(*d));
    if (!d) { close(copy); failure=ENOMEM; goto fail; }
    d->fd=copy; d->writable=writable; d->raw=S_ISCHR(st.st_mode); d->bytes=bytes; d->sector=sector;
    if (error) *error=0;
    return d;
fail:
    if (error) *error=failure;
    errno=failure; return NULL;
}

void nfsk_backend_free(void *opaque) {
    struct device *d=opaque; if (!d) return; close(d->fd); free(d);
}
/* raw字符设备要求内存、偏移及长度均扇区对齐；尾部写先读取原扇区，保留无关字节。 */
static int64_t aligned_io(struct device *d,void *buffer,int64_t offset,int64_t count,bool writing) {
    void *sector=NULL;
    if(posix_memalign(&sector,d->sector,d->sector)){errno=ENOMEM;return -1;}
    int64_t done=0;
    while(done<count) {
        uint64_t position=(uint64_t)(offset+done),base=position-position%d->sector;
        size_t within=(size_t)(position-base),take=d->sector-within;
        if((int64_t)take>count-done)take=(size_t)(count-done);
        ssize_t n;
        if(!writing || within || take!=d->sector) {
            do { n=pread(d->fd,sector,d->sector,(off_t)base); } while(n<0&&errno==EINTR);
            if(n!=(ssize_t)d->sector){if(n>=0)errno=EIO;free(sector);return -1;}
        }
        if(writing) {
            memcpy((char *)sector+within,(const char *)buffer+done,take);
            do { n=pwrite(d->fd,sector,d->sector,(off_t)base); } while(n<0&&errno==EINTR);
            if(n!=(ssize_t)d->sector){if(n>=0)errno=EIO;free(sector);return -1;}
        } else memcpy((char *)buffer+done,(char *)sector+within,take);
        done+=(int64_t)take;
    }
    free(sector);return done;
}
int64_t nfsk_block_pread(void *opaque, void *buffer, int64_t offset, int64_t count) {
    struct device *d=opaque;
    if (!d || offset<0 || count<0 || (uint64_t)offset>d->bytes || (uint64_t)count>SSIZE_MAX) { errno=EINVAL; return -1; }
    if ((uint64_t)count>d->bytes-(uint64_t)offset) count=(int64_t)(d->bytes-(uint64_t)offset);
    if(d->raw)return aligned_io(d,buffer,offset,count,false);
    ssize_t got; do { got=pread(d->fd,buffer,(size_t)count,offset); } while (got<0 && errno==EINTR);
    return got;
}
int64_t nfsk_block_pwrite(void *opaque, const void *buffer, int64_t offset, int64_t count) {
    struct device *d=opaque;
    if (!d) { errno=EINVAL; return -1; }
    if (!d->writable) { errno=EROFS; return -1; }
    if (offset<0 || count<0 || (uint64_t)offset>d->bytes || (uint64_t)count>d->bytes-(uint64_t)offset || (uint64_t)count>SSIZE_MAX) { errno=EINVAL; return -1; }
    if(d->raw)return aligned_io(d,(void *)buffer,offset,count,true);
    ssize_t wrote; do { wrote=pwrite(d->fd,buffer,(size_t)count,offset); } while (wrote<0 && errno==EINTR);
    return wrote;
}
int nfsk_block_sync(void *opaque) {
    struct device *d=opaque; if (!d) return -EINVAL;
    return fsync(d->fd)==0?0:-errno;
}
uint64_t nfsk_block_total_bytes(void *opaque) { return ((struct device *)opaque)->bytes; }
uint32_t nfsk_block_sector_size(void *opaque) { return ((struct device *)opaque)->sector; }
int nfsk_block_is_writable(void *opaque) { return ((struct device *)opaque)->writable; }
