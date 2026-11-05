import Foundation
import Darwin

@main enum FSKitWriteProbeTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        let token = UUID().uuidString
        for preparing in [true, false] {
            let args = try FSKitWriteProbe.arguments(userID: 501, token: token, preparing: preparing)
            let parsed = try FSKitWriteProbe.parse(args)
            check(parsed.0 == 501 && parsed.1 == token && parsed.2 == preparing)
        }
        for args in [
            [FSKitWriteProbe.mode, "0", token, "prepare"],
            [FSKitWriteProbe.mode, "0501", token, "prepare"],
            [FSKitWriteProbe.mode, "4294967295", token, "prepare"],
            [FSKitWriteProbe.mode, "501", "../other", "prepare"],
            [FSKitWriteProbe.mode, "501", token.lowercased(), "prepare"],
            [FSKitWriteProbe.mode, "501", token, "rw"],
            [FSKitWriteProbe.mode, "501", token, "status", "/tmp/other"],
            [FSKitMountBridge.mode, "501", token, "prepare"]
        ] {
            do { _ = try FSKitWriteProbe.parse(args); fatalError("无效内部参数被接受") }
            catch is HelperFailure { count += 1 }
        }
        for readOnly in [true, false] {
            let request = PrivilegedMountRequest(deviceID: "disk9999", mediaRegistryID: 9,
                wholeMediaRegistryID: 8, mediaByteCount: 67108864, readOnly: readOnly)
            let ticket = HelperTicket(userID: 501, token: token, request: request, backend: .fsKit)
            let options = try FSKitMountBridge.systemArguments(for: ticket)[4]
            check(options.contains("writeflow-ready-token=") == !readOnly)
            if !readOnly { check(options.hasSuffix("writeflow-ready-token=" + token)) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WriteFlow-FD-\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("stdin.txt")
        let payload = Data("仅普通文件：核验CLOEXEC句柄由stdin继承。".utf8)
        try payload.write(to: path)
        defer {
            precondition(unlink(path.path) == 0)
            precondition(rmdir(directory.path) == 0)
        }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { fatalError("普通文件准备失败") }
        defer { close(descriptor) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let result = try HelperCommand.runBridge("/bin/cat", [], timeout: 2, input: input)
        check(result == payload)
        check(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        check(lseek(descriptor, 0, SEEK_SET) == 0)
        check(try input.readToEnd() == payload)
        do {
            _ = try HelperCommand.runBridge("/bin/sleep", ["2"], timeout: 0.05)
            fatalError("超时未保留未知结果")
        } catch is HelperCommand.Uncertain { count += 1 }
        print("内部参数、stdin原FD继承及有界未知结果通过：\(count)项；没有设备/XPC/有效挂载。")
    }
}
