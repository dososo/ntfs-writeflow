/* GPL-2.0：固定安全选项，设备名只作为来源标记，不参与设备打开。 */
#include "legacy_volume.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

int wf_legacy_mount_options(char *buffer,size_t capacity,bool readonly,const char *device) {
    if(!buffer || !capacity)return -EINVAL;
    buffer[0]=0;
    if(!device || strncmp(device,"disk",4) || strlen(device)>63)return -EINVAL;
    const char *part=device+4;
    if(*part<'0'||*part>'9')return -EINVAL;
    while(*part) {
        while(*part>='0'&&*part<='9')part++;
        if(!*part)break;
        if(*part++!='s' || *part<'0' || *part>'9')return -EINVAL;
    }
    int n=snprintf(buffer,capacity,"%s,nosuid,nodev,noowners,nobrowse,allow_other,default_permissions,fsname=/dev/%s",readonly?"ro":"rw",device);
    if(n<0 || (size_t)n>=capacity){buffer[0]=0;return -ENAMETOOLONG;}
    return 0;
}
