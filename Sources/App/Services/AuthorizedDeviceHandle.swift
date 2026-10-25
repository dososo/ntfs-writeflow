import Foundation
import Darwin

// 前台应用通过系统 authopen 取得只读设备句柄，不为后台服务扩大磁盘访问权限。
enum AuthorizedDeviceHandle {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func devicePath(wholeDiskID: String) throws -> String {
        guard let match = wholeDiskID.range(of: #"^disk[0-9]+$"#, options: .regularExpression),
              match.lowerBound == wholeDiskID.startIndex, match.upperBound == wholeDiskID.endIndex else {
            throw Failure(message: "整盘标识无效，未请求设备访问授权。")
        }
        return "/dev/r" + wholeDiskID
    }

    static func open(wholeDiskID: String) async throws -> FileHandle {
        let path = try devicePath(wholeDiskID: wholeDiskID)
        try Task.checkCancellation()
        let state = DeviceOpenCancellation()
        let handle = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileHandle, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try acquire(path, state: state)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.cancel() }
        if Task.isCancelled {
            try? handle.close()
            throw CancellationError()
        }
        return handle
    }

    static func validateReadOnlyCharacterDevice(_ descriptor: Int32) throws {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptor >= 0, fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
              flags >= 0, flags & O_ACCMODE == O_RDONLY, flags & O_EVTONLY == 0,
              descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0 else {
            throw Failure(message: "系统未返回只读字符设备句柄，已停止弹出。")
        }
    }

    private static func acquire(_ path: String, state: DeviceOpenCancellation) throws -> FileHandle {
        try state.check()
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let direct = Darwin.open(path, flags)
        if direct >= 0 { return try checkedHandle(direct, state: state) }
        let directError = errno
        guard directError == EACCES || directError == EPERM else {
            throw Failure(message: "无法打开原整盘设备（\(directError)），未请求弹出。")
        }
        try state.check()
        var expectedNode = stat()
        guard lstat(path, &expectedNode) == 0, expectedNode.st_mode & S_IFMT == S_IFCHR else {
            throw Failure(message: "原始设备节点不是直接字符设备，未请求授权。")
        }
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw Failure(message: "无法建立系统授权句柄通道，未请求弹出。")
        }
        let receiver = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let sender = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        defer { try? receiver.close(); try? sender.close() }
        guard fcntl(sockets[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(sockets[1], F_SETFD, FD_CLOEXEC) == 0 else {
            throw Failure(message: "无法保护授权通道描述符，未请求弹出。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        // 本机 authopen 对 O_NOFOLLOW 返回 EINVAL；/dev 由系统管理，先 lstat 拒绝符号链接。
        // 收到后核对原节点号，共享弹出校验还会核对原 IOMedia 身份和精确设备号；之前不读取设备内容。
        process.arguments = ["-stdoutpipe", "-o", String(O_RDONLY | O_CLOEXEC), path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = sender
        let diagnostic = Pipe()
        process.standardError = diagnostic
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        try state.launch(process)
        // 父进程及时关闭发送端，用户取消或子进程失败时 recvmsg 才能收到 EOF。
        try sender.close()
        let descriptor = writeflow_receive_device_descriptor(receiver.fileDescriptor)
        let receiveError = errno
        process.waitUntilExit()
        let detail = String(decoding: diagnostic.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
        state.finished()
        if descriptor < 0 {
            try state.check()
            throw Failure(message: "未取得整盘读取授权或授权已取消（\(process.terminationStatus)/\(receiveError)）；卷可能已卸载，但尚未弹出。\n\(detail)")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            close(descriptor)
            try state.check()
            throw Failure(message: "系统设备授权未完成，尚未弹出整盘。")
        }
        var actualNode = stat()
        guard fstat(descriptor, &actualNode) == 0, actualNode.st_rdev == expectedNode.st_rdev else {
            close(descriptor)
            throw Failure(message: "系统返回的设备节点已变化，尚未弹出整盘。")
        }
        return try checkedHandle(descriptor, state: state)
    }

    private static func checkedHandle(_ descriptor: Int32, state: DeviceOpenCancellation) throws -> FileHandle {
        do {
            try state.check()
            try validateReadOnlyCharacterDevice(descriptor)
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch { close(descriptor); throw error }
    }
}

private final class DeviceOpenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func launch(_ child: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            // 启动和登记在同一锁内，避免取消恰好发生于检查和启动之间。
            try child.run()
            process = child
        }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
    func finished() { lock.withLock { process = nil } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
