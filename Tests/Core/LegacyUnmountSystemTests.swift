import Foundation
import Darwin

// 只接受调用脚本新建的HFS+镜像；真实执行生产旧路径的同步及正常卸载原语。
// root目录租约由普通用户目录检查替代，不将此结果算作root/FUSE生产链验收。
@main enum LegacyUnmountSystemTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("用法：测试程序 自建挂载点 精确镜像设备路径") }
        let path = CommandLine.arguments[1], device = CommandLine.arguments[2]
        guard path.hasPrefix("/private/tmp/WriteFlow-旧卸载-") else { fatalError("只允许测试私有目录") }
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(descriptor >= 0)
        defer { close(descriptor) }
        guard let before = MountedFileSystemReader.read(descriptor: descriptor),
              before.type == "hfs", before.source == device, before.mountPoint == path else {
            fatalError("不是调用方新建的预期HFS+镜像")
        }
        let payload = URL(fileURLWithPath: path).appendingPathComponent("卸载前写入.txt")
        try Data("真实同步与正常卸载\n".utf8).write(to: payload)
        var leaseChecks = 0, mediaChecks = 0
        try ManagedUnmount.executeLegacy(descriptor: descriptor, expected: before,
            validateLease: {
                leaseChecks += 1
                var status = stat()
                precondition(lstat((path as NSString).deletingLastPathComponent, &status) == 0)
                precondition(status.st_uid == geteuid() && status.st_mode & 0o777 == 0o700)
            }, validateMedia: {
                mediaChecks += 1
                precondition(MountedFileSystemReader.read(descriptor: descriptor)?.source == device)
            }, operations: ManagedUnmount.Operations())
        precondition(leaseChecks == 2 && mediaChecks == 2)
        precondition(MountedFileSystemReader.read(path: path)?.identity != before.identity)
        print("通过：生产旧路径在自建HFS+镜像执行真实fsync与unmount(path,0)，前后双核验；不是root租约、macFUSE挂载或旧系统实机验收。")
    }
}
