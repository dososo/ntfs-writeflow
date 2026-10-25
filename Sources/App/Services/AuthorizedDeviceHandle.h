#ifndef WRITEFLOW_AUTHORIZED_DEVICE_HANDLE_H
#define WRITEFLOW_AUTHORIZED_DEVICE_HANDLE_H

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

// 只接收一个 SCM_RIGHTS 描述符。缓冲区覆盖 XNU 的 UIPC_MAX_CMSG_FD（512）上限。
// 拒绝截断、多描述符和其他辅助消息，并关闭已经收到的副本。
static inline int writeflow_receive_device_descriptor(int channel) {
    char payload[1];
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 512)]; } control;
    memset(&control, 0, sizeof(control));
    struct iovec vector = { .iov_base = payload, .iov_len = sizeof(payload) };
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    ssize_t length;
    do { length = recvmsg(channel, &message, 0); } while (length < 0 && errno == EINTR);
    if (length < 0) return -1;
    int descriptor = -1, count = 0;
    int invalid = length == 0 || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_len < CMSG_LEN(0) ||
            (char *)header + header->cmsg_len > control.bytes + message.msg_controllen) {
            invalid = 1;
            break;
        }
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
            invalid = 1;
            continue;
        }
        size_t bytes = header->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int)) invalid = 1;
        for (size_t index = 0; index < bytes / sizeof(int); index++) {
            int received;
            memcpy(&received, CMSG_DATA(header) + index * sizeof(int), sizeof(received));
            if (count++ == 0) descriptor = received;
            else close(received);
        }
    }
    if (invalid || count != 1 || descriptor < 0) {
        if (descriptor >= 0) close(descriptor);
        errno = EPROTO;
        return -1;
    }
    int flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0) {
        int error = errno;
        close(descriptor);
        errno = error;
        return -1;
    }
    return descriptor;
}

#endif
