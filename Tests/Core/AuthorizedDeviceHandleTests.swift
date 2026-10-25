import Foundation
import Darwin

@main enum AuthorizedDeviceHandleTests {
    static func main() throws {
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
        print("通过：\(checks) 项授权路径与只读字符描述符检查；未调用authopen、未打开任何磁盘设备。")
    }
}
