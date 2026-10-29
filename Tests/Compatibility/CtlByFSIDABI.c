/* 只编译公开结构及常量；不包含或调用 sysctl、卸载、挂载入口。
 * 编译成功只说明当前 SDK 可表达此 ABI，不能证明挂载身份原子绑定。
 */
#include <sys/mount.h>
#include <stddef.h>

_Static_assert(VFS_CTL_VERS1 == 1, "公开请求版本变化");
_Static_assert(VFS_CTL_UMOUNT == 0x00010002, "公开选择器变化");
_Static_assert(sizeof(((struct vfsidctl *)0)->vc_fsid) == sizeof(fsid_t), "编号结构变化");
_Static_assert(offsetof(struct vfsidctl, vc_fsid) > offsetof(struct vfsidctl, vc_vers), "公开字段布局变化");
