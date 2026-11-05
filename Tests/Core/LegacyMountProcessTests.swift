import Foundation
import Darwin

@main enum LegacyMountProcessTests {
    static func main() throws {
        let token = UUID().uuidString
        let request = PrivilegedMountRequest(deviceID: "disk99s1", mediaRegistryID: 42,
            wholeMediaRegistryID: 41, mediaByteCount: 134217728, readOnly: false)
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        let args = try LegacyMountProcess.arguments(request, userID: 501, token: token)
        precondition(args == ["--mount", path, "--uid", "501", "--bytes", "134217728", "--readonly", "0",
            "--runtime", String(path.dropLast(7)) + "/runtime/libfuse.2.dylib", "--device", "disk99s1", "--media-id", "41"])
        for uid: UInt32 in [0, 500, .max] {
            do { _ = try LegacyMountProcess.arguments(request, userID: uid, token: token); fatalError("非法用户不能启动") }
            catch { }
        }
        let expected = MountedFileSystem(type: "macfuse", source: "/dev/disk99s1", mountPoint: path,
            identity: "42:17", ownerID: 0, isReadOnly: false)
        var clock = 0.0
        var validations = 0
        let mounted = try LegacyMountProcess.waitForMount(request, path: path, timeout: 1,
            mounted: { clock > 0 ? expected : nil }, running: { true }, status: { 0 },
            validate: { validations += 1 }, now: { clock }, pause: { clock += 0.1 })
        precondition(mounted == expected && validations >= 2)
        for kind in [0, 1, 2, 3] {
            clock = 0
            var checks = 0
            do {
                _ = try LegacyMountProcess.waitForMount(request, path: path, timeout: 0.2,
                    mounted: { kind == 0 ? expected : nil }, running: { kind != 0 && kind != 1 }, status: { 74 },
                    validate: { checks += 1; if kind == 3 { throw NSError(domain: "介质变化", code: 1) } },
                    now: { clock }, pause: { clock += 0.1 })
                fatalError("已退出、预检失败、超时或介质变化不能报告挂载成功")
            } catch { precondition(checks > 0) }
        }
        let filePath = "/private/tmp/writeflow-收尾-\(UUID().uuidString)"
        let descriptor = open(filePath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        precondition(descriptor >= 0)
        defer { close(descriptor); precondition(unlink(filePath) == 0) }
        let ticket = HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: expected.identity)
        for kind in 0..<7 {
            var receipt: [String: Any] = ["version": 1, "userID": 501,
                "wholeMediaRegistryID": 41, "token": token, "status": kind == 1 ? 74 : 0]
            if kind == 3 { receipt["token"] = UUID().uuidString }
            let data = kind == 4 ? Data() : Data([kind == 2 ? 0 : 1]) + (try JSONSerialization.data(withJSONObject: receipt))
            precondition(ftruncate(descriptor, 0) == 0)
            precondition(data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == data.count)
            clock = 0
            do {
                let lock = try LegacyMountProcess.waitForClose(ticket, timeout: 0.2,
                    lease: { FileHandle(fileDescriptor: fcntl(descriptor, F_DUPFD_CLOEXEC, 3), closeOnDealloc: true) },
                    running: { kind == 6 }, exitStatus: { kind == 5 ? 74 : 0 },
                    now: { clock }, pause: { clock += 0.1 })
                try lock.close()
                precondition(kind == 0, "最终错误、未知/旧回执或进程未收尾都不能报告成功")
            } catch { precondition(kind != 0) }
        }
        print("通过：固定兼容参数、非法身份、真实结果后置核验、退出/预检/超时/身份变化及最终收尾错误/未知/旧回执拒绝；仅自有普通回执文件，无设备操作。")
    }
}
