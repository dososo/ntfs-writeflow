/* GPL-2.0：阻止非法fstypename及设备名选项注入回归；不调用系统挂载。 */
#include "legacy_volume.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
static int count;
#define CHECK(x) do {count++;if(!(x)){fprintf(stderr,"失败：%s 第%d行\n",#x,__LINE__);return 1;}}while(0)
static int option(const char *text,const char *value) {
    size_t length=strlen(value);const char *p=text;
    while(p && *p){const char *end=strchr(p,',');size_t n=end?(size_t)(end-p):strlen(p);if(n==length&&!memcmp(p,value,n))return 1;p=end?end+1:NULL;}
    return 0;
}
int main(void) {
    char text[320];
    for(int readonly=0;readonly<=1;readonly++) {
        CHECK(wf_legacy_mount_options(text,sizeof(text),readonly,"disk42s1")==0);
        CHECK(option(text,readonly?"ro":"rw") && !option(text,readonly?"rw":"ro"));
        CHECK(option(text,"nosuid") && option(text,"nodev") && option(text,"noowners") && option(text,"nobrowse"));
        CHECK(option(text,"allow_other") && option(text,"default_permissions"));
        CHECK(option(text,"fsname=/dev/disk42s1"));
        CHECK(strstr(text,"fstypename=")==NULL);
        CHECK(!option(text,"force") && !option(text,"suid") && !option(text,"dev"));
    }
    const char *invalid[]={"disk42s1,allow_root","disk42s1 -o force","/dev/disk42","../disk42","disk","disk1s","disk1s2/other"};
    for(size_t i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++) {
        strcpy(text,"不能使用的旧结果");
        CHECK(wf_legacy_mount_options(text,sizeof(text),false,invalid[i])==-EINVAL && text[0]==0);
    }
    CHECK(wf_legacy_mount_options(text,8,false,"disk42s1")==-ENAMETOOLONG && text[0]==0);
    printf("通过：%d项ro/rw安全选项、默认文件系统类型、来源及选项注入检查。\n",count);return 0;
}
