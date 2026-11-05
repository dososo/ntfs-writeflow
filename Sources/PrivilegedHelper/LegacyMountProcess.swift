import Foundation
import Darwin

// 兼容进程持有媒体FD与跨服务重启的互斥锁；只从root私有验签副本执行。
final class LegacyMountProcess {
    let process = Process()
    let mediaRegistryID: UInt64
    private let mediaLease: FileHandle

    init(_ request: PrivilegedMountRequest, userID: UInt32, ticket: HelperTicket,
         namespace: HelperNamespace, handle: FileHandle) throws {
        mediaRegistryID = request.mediaRegistryID
        mediaLease = try namespace.mediaLease(for: request)
        if let previous = try LegacyReceipt.read(from: mediaLease.fileDescriptor) {
            try previous.requireClean(wholeMediaRegistryID: request.wholeMediaRegistryID)
        }
        let directory = try namespace.runtimeDirectory(for: ticket)
        defer { close(directory) }
        _ = try LegacyRuntime.prepareLibrary(in: directory, userID: userID, token: ticket.token)
        var executable = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0 else {
            throw HelperFailure(message: "无法确认管理员服务位置，已停止兼容挂载。")
        }
        let ownPath = String(decoding: executable.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let source = URL(fileURLWithPath: ownPath).deletingLastPathComponent().appendingPathComponent("NTFSWriteFlowLegacy")
        let child = try LegacyRuntime.prepareExecutable(in: directory, userID: userID, token: ticket.token, source: source)
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", String(userID), child] + (try Self.arguments(request, userID: userID, token: ticket.token))
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = handle
        process.standardOutput = mediaLease
        // 不用会在服务崩溃后造成SIGPIPE的日志管道。错误由受限退出码及系统日志定位。
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 只由已启动的child持锁，父进程退出或恢复后可重新获得锁核验收尾。
        try? mediaLease.close()
    }

    static func arguments(_ request: PrivilegedMountRequest, userID: UInt32, token: String) throws -> [String] {
        let invocation = try HelperCommand.mountInvocation(request, userID: userID, token: token)
        guard request.wholeMediaRegistryID > 0, request.mediaByteCount > 0 else {
            throw HelperFailure(message: "兼容挂载的完整介质身份无效。")
        }
        let path = invocation.1.last!
        return ["--mount", path, "--uid", String(userID), "--bytes", String(request.mediaByteCount),
                "--readonly", request.readOnly ? "1" : "0", "--runtime", try LegacyRuntime.cachePath(userID: userID, token: token),
                "--device", request.deviceID, "--media-id", String(request.wholeMediaRegistryID)]
    }

    static func waitForClose(_ ticket: HelperTicket, timeout: TimeInterval = 10,
                             lease: () throws -> FileHandle, running: () -> Bool,
                             exitStatus: () -> Int32?,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) throws -> FileHandle {
        let deadline = now() + timeout
        while true {
            if !running() {
                if let code = exitStatus(), code != 0 {
                    throw HelperFailure(message: "卷已卸载，但兼容后端收尾失败（\(code)）；已保留凭据，请勿继续写入或弹盘。")
                }
                let acquired: FileHandle?
                do { acquired = try lease() }
                catch { acquired = nil }
                if let acquired {
                    do {
                        guard let receipt = try LegacyReceipt.read(from: acquired.fileDescriptor) else {
                            throw HelperFailure(message: "缺少兼容后端的持久收尾回执。")
                        }
                        try receipt.requireClean(wholeMediaRegistryID: ticket.request.wholeMediaRegistryID,
                            userID: ticket.userID, token: ticket.token)
                        return acquired
                    } catch {
                        try? acquired.close()
                        throw HelperFailure(message: "卷已卸载，但兼容后端收尾未确认；保留凭据，不会报告成功。\(error.localizedDescription)")
                    }
                }
            }
            guard now() < deadline else {
                throw HelperFailure(message: "卷已卸载，但兼容后端仍在收尾或持有媒体锁；已保留凭据，请稍后刷新，不会强制结束。")
            }
            pause()
        }
    }

    static func waitForMount(_ request: PrivilegedMountRequest, path: String, timeout: TimeInterval = 30,
                             mounted: () -> MountedFileSystem?, running: () -> Bool, status: () -> Int32,
                             validate: () throws -> Void,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) throws -> MountedFileSystem {
        let deadline = now() + timeout
        while true {
            try validate()
            guard running() else {
                let code = status()
                let detail = code == 74 ? "只读预检或设备I/O失败，请停止写入并检查卷状态。"
                    : code == 78 ? "macFUSE运行时无法加载，请核对官方安装与系统批准。"
                    : "请核对macFUSE的系统批准和设备状态。"
                throw HelperFailure(message: "兼容挂载进程已退出（\(code)）。\(detail)")
            }
            if let result = mounted() {
                guard result.type == "macfuse", result.source == "/dev/\(request.deviceID)",
                      result.mountPoint == path, result.ownerID == 0, result.isReadOnly == request.readOnly else {
                    throw HelperFailure(message: "兼容挂载的来源、身份或访问模式不符，未报告成功。")
                }
                try validate()
                return result
            }
            guard now() < deadline else {
                // 进程可能已提交内核挂载，不能以超时强杀；保留锁、进程和票据供刷新恢复。
                throw HelperFailure(message: "兼容挂载尚未返回，已保留媒体锁与凭据，请刷新状态后再试。")
            }
            pause()
        }
    }
}
