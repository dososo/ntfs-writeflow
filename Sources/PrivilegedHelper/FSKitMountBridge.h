#pragma once
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

/* 仅在重新exec的私有助手模式调用，不在多线程daemon的fork分支调用。 */
static inline int writeflow_exec_fskit_mount(uint32_t user_id, const char *options,
                                            const char *device, const char *mount_point) {
    if (getuid() != 0 || geteuid() != 0 || user_id < 501 || user_id == UINT32_MAX) return EPERM;
    char *arguments[] = {"/sbin/mount", "-F", "-t", "blntfs", "-o",
                         (char *)options, (char *)device, (char *)mount_point, NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL};
    if (setreuid((uid_t)user_id, 0) != 0) return errno;
    if (getuid() != user_id || geteuid() != 0) return EPERM;
    execve("/sbin/mount", arguments, environment);
    return errno;
}
