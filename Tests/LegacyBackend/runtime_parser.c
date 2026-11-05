/* GPL-2.0：仅调用官方库无挂载副作用的版本及参数解析入口。 */
#include "legacy_volume.h"
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static int count;
#define CHECK(x) do {count++;if(!(x)){fprintf(stderr,"解析核验失败：%s，第%d行\n",#x,__LINE__);return 1;}}while(0)
struct parsed {
    int readonly, nosuid, nodev, noowners, nobrowse, allow_other, permissions;
    char *source;
};
static const struct fuse_opt options[]={
    {"ro",offsetof(struct parsed,readonly),1},
    {"rw",offsetof(struct parsed,readonly),0},
    {"nosuid",offsetof(struct parsed,nosuid),1},
    {"nodev",offsetof(struct parsed,nodev),1},
    {"noowners",offsetof(struct parsed,noowners),1},
    {"nobrowse",offsetof(struct parsed,nobrowse),1},
    {"allow_other",offsetof(struct parsed,allow_other),1},
    {"default_permissions",offsetof(struct parsed,permissions),1},
    {"fsname=%s",offsetof(struct parsed,source),0},
    FUSE_OPT_END
};

int main(int argc,char **argv) {
    if(argc!=3)return 64;
    /* 运行时字节保持官方签名原状；测试进程单独提供DYLD_FRAMEWORK_PATH。 */
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!library){fprintf(stderr,"官方库无法加载，未执行解析入口：%s\n",dlerror());return 78;}
    typedef int (*version_fn)(void);
    typedef int (*command_fn)(struct fuse_args *,char **,int *,int *);
    typedef int (*options_fn)(struct fuse_args *,void *,const struct fuse_opt [],fuse_opt_proc_t);
    typedef void (*free_fn)(struct fuse_args *);
    version_fn version=(version_fn)dlsym(library,"fuse_version");
    command_fn command=(command_fn)dlsym(library,"fuse_parse_cmdline");
    options_fn parse=(options_fn)dlsym(library,"fuse_opt_parse");
    free_fn release=(free_fn)dlsym(library,"fuse_opt_free_args");
    CHECK(version && command && parse && release);
    int api=version();CHECK(api>=26);
    char canonical[4096];CHECK(realpath(argv[2],canonical)!=NULL);
    for(int readonly=0;readonly<=1;readonly++) {
        char generated[320];CHECK(wf_legacy_mount_options(generated,sizeof(generated),readonly!=0,"disk42s1")==0);
        CHECK(strstr(generated,"fstypename=")==NULL);
        char *arguments[]={"NTFSWriteFlowLegacy","-f","-s","-o",generated,argv[2],NULL};
        struct fuse_args args=FUSE_ARGS_INIT(6,arguments);
        char *mountpoint=NULL;int multithreaded=-1,foreground=-1;
        CHECK(command(&args,&mountpoint,&multithreaded,&foreground)==0);
        CHECK(mountpoint && !strcmp(mountpoint,canonical));
        CHECK(multithreaded==0 && foreground==1);
        struct parsed state={.readonly=-1};
        CHECK(parse(&args,&state,options,NULL)==0);
        CHECK(state.readonly==readonly);
        CHECK(state.nosuid && state.nodev && state.noowners && state.nobrowse);
        CHECK(state.allow_other && state.permissions);
        CHECK(state.source && !strcmp(state.source,"/dev/disk42s1"));
        free(state.source);free(mountpoint);release(&args);
    }
    int translated=0;size_t size=sizeof(translated);
    (void)sysctlbyname("sysctl.proc_translated",&translated,&size,NULL,0);
#if defined(__x86_64__)
    const char *architecture="x86_64";
#elif defined(__arm64__)
    const char *architecture="arm64";
#else
    const char *architecture="未知";
#endif
    printf("通过：%d项官方库版本/命令行/选项解析；API=%d，架构=%s，Rosetta=%d。未调用挂载或内核加载入口。\n",count,api,architecture,translated);
    dlclose(library);return 0;
}
