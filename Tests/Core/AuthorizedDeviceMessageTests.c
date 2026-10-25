#include "../../Sources/App/Services/AuthorizedDeviceHandle.h"
#include <stdio.h>
#include <stdlib.h>

static int checks = 0;
static void check(int ok, const char *label) {
    if (!ok) { fprintf(stderr, "失败：%s（errno=%d）\n", label, errno); exit(1); }
    checks++;
}
static int count_fds(void) {
    int count = 0;
    for (int i = 0; i < 512; i++) if (fcntl(i, F_GETFD) >= 0) count++;
    return count;
}
static void send_descriptors(int channel, int descriptor, size_t count, int payload_length) {
    char payload[2] = { 'a', 'b' };
    struct iovec vector = { .iov_base = payload, .iov_len = (size_t)payload_length };
    size_t size = count ? CMSG_SPACE(count * sizeof(int)) : 0;
    void *control = count ? calloc(1, size) : NULL;
    struct msghdr message = { 0 };
    message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = control; message.msg_controllen = (socklen_t)size;
    if (count) {
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(count * sizeof(int));
        for (size_t i = 0; i < count; i++) memcpy(CMSG_DATA(header) + i * sizeof(int), &descriptor, sizeof(int));
    }
    check(sendmsg(channel, &message, 0) == payload_length, "发送本地测试辅助消息");
    free(control);
}
int main(void) {
    int descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC);
    check(descriptor >= 0, "打开空设备，不接触磁盘");
    for (int scenario = 0; scenario < 6; scenario++) {
        int channel[2];
        check(socketpair(AF_UNIX, SOCK_DGRAM, 0, channel) == 0, "新建独立本地通道");
        int before = count_fds();
        size_t count = scenario == 0 ? 1 : scenario == 1 ? 2 : scenario == 2 ? 65 : scenario == 3 ? 0 : 1;
        if (scenario == 5) {
            // 无辅助消息的普通内容不是句柄授权。
            check(send(channel[0], "x", 1, 0) == 1, "发送无句柄内容");
        } else { send_descriptors(channel[0], descriptor, count, scenario == 4 ? 2 : 1); }
        int received = writeflow_receive_device_descriptor(channel[1]);
        if (scenario == 0) {
            check(received >= 0 && received != descriptor, "单句柄接收为独立副本");
            check((fcntl(received, F_GETFD) & FD_CLOEXEC) != 0, "接收句柄设置CLOEXEC");
            close(received);
            check(fcntl(descriptor, F_GETFD) >= 0, "关闭副本不关闭发送者句柄");
        } else {
            check(received == -1 && errno == EPROTO, "多句柄、截断或无句柄消息拒绝");
        }
        int after = count_fds();
        if (after != before) fprintf(stderr, "场景=%d 前=%d 后=%d\n", scenario, before, after);
        check(after == before, "拒绝路径不泄漏已收到的任何描述符");
        close(channel[0]); close(channel[1]);
    }
    int eof_channel[2];
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, eof_channel) == 0, "建立退出模拟通道");
    close(eof_channel[0]);
    check(writeflow_receive_device_descriptor(eof_channel[1]) == -1 && errno == EPROTO,
          "授权子进程退出无句柄时返回错误，不持续等待");
    close(eof_channel[1]);
    close(descriptor);
    printf("通过：%d 项SCM_RIGHTS接收、截断、多句柄拒绝及无泄漏检查；未操作磁盘。\n", checks);
    return 0;
}
