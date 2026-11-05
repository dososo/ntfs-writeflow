import Foundation
import Darwin

@main enum AuthorizedDeviceHandleTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(name) }
            catch { checks += 1 }
        }
        check(try AuthorizedDeviceHandle.devicePath(wholeDiskID: "disk0") == "/dev/rdisk0", "只派生整盘原始设备路径")
        check(try AuthorizedDeviceHandle.devicePath(wholeDiskID: "disk123") == "/dev/rdisk123", "接受多位整盘编号")
        for value in ["", "disk", "disk1s1", "/dev/disk1", "../disk1", "disk1;echo x",
                      "disk1\n", "disk1\r", "disk1\u{2028}", "disk-1", "disk١", " disk1", "disk1 "] {
            rejected("拒绝非法或分区路径") { _ = try AuthorizedDeviceHandle.devicePath(wholeDiskID: value) }
        }
        rejected("拒绝无效描述符") { try AuthorizedDeviceHandle.validateReadOnlyCharacterDevice(-1) }
        let null = open("/dev/null", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        check(null >= 0, "只读空设备可打开")
        defer { close(null) }
        try AuthorizedDeviceHandle.validateReadOnlyCharacterDevice(null)
        checks += 1
        let writeOnly = open("/dev/null", O_WRONLY | O_CLOEXEC)
        check(writeOnly >= 0, "仅打开空设备用于权限拒绝测试，不写入")
        defer { close(writeOnly) }
        rejected("拒绝可写设备句柄") { try AuthorizedDeviceHandle.validateReadOnlyCharacterDevice(writeOnly) }
        let inheritable = open("/dev/null", O_RDONLY)
        check(inheritable >= 0, "仅打开空设备验证继承标志")
        defer { close(inheritable) }
        rejected("拒绝缺少CLOEXEC") { try AuthorizedDeviceHandle.validateReadOnlyCharacterDevice(inheritable) }
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        check(directory >= 0, "只读取目录元数据")
        defer { close(directory) }
        rejected("目录不能冒充字符设备") { try AuthorizedDeviceHandle.validateReadOnlyCharacterDevice(directory) }
        for identifier in ["disk0", "disk1s2", "disk123s45s6"] {
            check(try AuthorizedDeviceHandle.devicePath(deviceID: identifier) == "/dev/r" + identifier,
                  "只派生精确原始宗卷路径")
        }
        for value in ["", "disk", "disk1s", "/dev/disk1s2", "../disk1s2", "rdisk1s2", "disk1s2/../null",
                      "disk1s2;echo x", "disk1s2\n", "disk1s2\r", "disk1s2\u{2028}", "disk١s٢", " disk1s2", "disk1s2 "] {
            rejected("拒绝不完整或可逃逸的宗卷标识") { _ = try AuthorizedDeviceHandle.devicePath(deviceID: value) }
        }
        for readOnly in [true, false] {
            let access = readOnly ? O_RDONLY : O_RDWR
            let direct = AuthorizedDeviceHandle.requestedOpenFlags(readOnly: readOnly)
            check(direct & O_ACCMODE == access && direct & O_CLOEXEC != 0 && direct & O_NOFOLLOW != 0,
                  "普通打开使用精确访问模式及禁止跟随和继承")
            let authorized = AuthorizedDeviceHandle.requestedOpenFlags(readOnly: readOnly, authorization: true)
            check(authorized & O_ACCMODE == access && authorized & O_CLOEXEC != 0 && authorized & O_NOFOLLOW == 0,
                  "authopen只省略其不支持的NOFOLLOW")
            check((direct | authorized) & (O_TRUNC | O_CREAT | O_APPEND) == 0, "设备授权不截断、不创建或追加")
        }
        let readWrite = open("/dev/null", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        check(readWrite >= 0, "空设备读写句柄可打开；不写入")
        defer { close(readWrite) }
        let node = try AuthorizedDeviceHandle.characterDeviceID(at: "/dev/null")
        try AuthorizedDeviceHandle.validateCharacterDevice(readWrite, readOnly: false, expectedDevice: node)
        checks += 1
        try AuthorizedDeviceHandle.validateCharacterDevice(null, readOnly: true, expectedDevice: node)
        checks += 1
        rejected("只读请求拒绝读写描述符") {
            try AuthorizedDeviceHandle.validateCharacterDevice(readWrite, readOnly: true, expectedDevice: node)
        }
        rejected("读写请求拒绝只读描述符") {
            try AuthorizedDeviceHandle.validateCharacterDevice(null, readOnly: false, expectedDevice: node)
        }
        rejected("读写请求拒绝只写描述符") {
            try AuthorizedDeviceHandle.validateCharacterDevice(writeOnly, readOnly: false, expectedDevice: node)
        }
        rejected("字符设备节点号变化拒绝") {
            try AuthorizedDeviceHandle.validateCharacterDevice(readWrite, readOnly: false, expectedDevice: node ^ 1)
        }
        let inheritableReadWrite = open("/dev/null", O_RDWR)
        check(inheritableReadWrite >= 0, "打开匹配访问模式但可继承的空设备句柄")
        defer { close(inheritableReadWrite) }
        rejected("读写请求同样要求CLOEXEC") {
            try AuthorizedDeviceHandle.validateCharacterDevice(inheritableReadWrite, readOnly: false, expectedDevice: node)
        }
        rejected("目录不能作为授权前节点") { _ = try AuthorizedDeviceHandle.characterDeviceID(at: "/") }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("writeflow-node-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/null")
        defer { try? FileManager.default.removeItem(at: link) }
        rejected("授权前拒绝符号链接，即使目标为字符设备") {
            _ = try AuthorizedDeviceHandle.characterDeviceID(at: link.path)
        }
        do {
            _ = try await AuthorizedDeviceHandle.openVolume(deviceID: "../null", readOnly: false)
            preconditionFailure("非法宗卷请求必须在设备访问前拒绝")
        } catch { checks += 1 }
        let cancelled = Task<FileHandle, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AuthorizedDeviceHandle.openVolume(deviceID: "disk999999999s1", readOnly: false)
        }
        do { _ = try await cancelled.value; preconditionFailure("已取消请求不能打开设备") }
        catch is CancellationError { checks += 1 }
        print("通过：\(checks) 项整盘／宗卷路径、访问模式和节点身份检查；只使用/dev/null与自有符号链接，未调用authopen、未打开磁盘。")
    }
}
