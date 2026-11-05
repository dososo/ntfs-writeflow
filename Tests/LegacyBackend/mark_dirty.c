/* GPL-2.0：只用于本轮全新普通文件；写入脏标记并模拟进程未正常关闭。 */
#include "config.h"
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/layout.h>
int main(int argc,char **argv) {
    struct stat st;if(argc!=2||lstat(argv[1],&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1)return 2;
    ntfs_volume *v=ntfs_mount(argv[1],0);if(!v)return 1;
    if(ntfs_volume_write_flags(v,v->flags|VOLUME_IS_DIRTY)||v->dev->d_ops->sync(v->dev))return 1;
    _exit(0);
}
