#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* 仅替换系统调用结果，执行生产C桥；不改真实UID，不执行mount。 */
static uid_t real_id, effective_id;
static int change_error, keep_real_id, change_calls, exec_calls;
static uid_t test_getuid(void) { return real_id; }
static uid_t test_geteuid(void) { return effective_id; }
static int test_setreuid(uid_t real, uid_t effective) {
    change_calls++;
    if (change_error) { errno = change_error; return -1; }
    if (!keep_real_id) real_id = real;
    effective_id = effective;
    return 0;
}
static int test_execve(const char *path, char *const argv[], char *const env[]) {
    exec_calls++;
    assert(strcmp(path, "/sbin/mount") == 0 && strcmp(argv[0], path) == 0);
    const char *expected[] = {"-F", "-t", "blntfs", "-o", "ro,nosuid,nodev,noowners,nobrowse,writeflow-media-id=123",
                             "/dev/disk99s1", "/固定目标"};
    for (int i = 0; i < 7; i++) assert(strcmp(argv[i + 1], expected[i]) == 0);
    assert(argv[8] == NULL && strcmp(env[0], "PATH=/usr/bin:/bin:/usr/sbin:/sbin") == 0);
    assert(strcmp(env[1], "LANG=C") == 0 && env[2] == NULL);
    errno = ENOENT;
    return -1;
}
#define getuid test_getuid
#define geteuid test_geteuid
#define setreuid test_setreuid
#define execve test_execve
#include "../../Sources/PrivilegedHelper/FSKitMountBridge.h"
#undef getuid
#undef geteuid
#undef setreuid
#undef execve

int main(void) {
    assert(geteuid() != 0);
    const char *options = "ro,nosuid,nodev,noowners,nobrowse,writeflow-media-id=123";
    real_id = 0; effective_id = 0; change_error = EACCES;
    assert(writeflow_exec_fskit_mount(501, options, "/dev/disk99s1", "/固定目标") == EACCES);
    assert(change_calls == 1 && exec_calls == 0);
    change_error = 0; keep_real_id = 1;
    assert(writeflow_exec_fskit_mount(501, options, "/dev/disk99s1", "/固定目标") == EPERM);
    assert(change_calls == 2 && exec_calls == 0);
    keep_real_id = 0;
    assert(writeflow_exec_fskit_mount(501, options, "/dev/disk99s1", "/固定目标") == ENOENT);
    assert(real_id == 501 && effective_id == 0 && change_calls == 3 && exec_calls == 1);
    for (int i = 0; i < 3; i++) {
        real_id = 0; effective_id = 0;
        const uint32_t invalid[] = {0, 500, UINT32_MAX};
        assert(writeflow_exec_fskit_mount(invalid[i], options, "/dev/disk99s1", "/固定目标") == EPERM);
    }
    real_id = 501; effective_id = 0;
    assert(writeflow_exec_fskit_mount(501, options, "/dev/disk99s1", "/固定目标") == EPERM);
    assert(change_calls == 3 && exec_calls == 1);
    puts("C桥7组通过：转换失败、转换后身份不符、固定exec失败、非法UID三组、初始真实UID非root；仅模拟系统调用，无提权/设备操作。");
    return 0;
}
