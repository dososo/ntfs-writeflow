import Foundation
import Darwin

@main struct ObservationTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            count += 1
            print("通过：\(name)")
        }
        let mount = ObservedMountIdentity(fileSystemID: [1, 2], source: "/dev/disk-test", mountPoint: "/自有测试")
        let original = ObservedDiskIdentity(retainedMediaID: 123, namedMediaID: 123, mediaActive: true,
                                            deviceName: "disk-test", descriptorMount: mount)
        check(original.agrees(with: original), "相同完整快照")
        var current = original; current.namedMediaID = 124
        check(!original.agrees(with: current), "同设备名换介质拒绝")
        current = original; current.mediaActive = false
        check(!original.agrees(with: current), "介质离线拒绝")
        current = original; current.retainedMediaID = 0; current.namedMediaID = 0
        check(!current.agrees(with: current), "缺失身份拒绝")
        current = original; current.descriptorMount.fileSystemID = [3, 4]
        check(!original.agrees(with: current), "挂载实例变化拒绝")
        current = original; current.descriptorMount.source = "/dev/other"
        check(!original.agrees(with: current), "挂载来源变化拒绝")
        current = original; current.descriptorMount.mountPoint = "/other"
        check(!original.agrees(with: current), "挂载位置变化拒绝")
        current = original; current.deviceName = "other"
        check(!original.agrees(with: current), "设备名变化拒绝")
        current = original; current.descriptorMount.fileSystemID = []
        check(!current.agrees(with: current), "缺失挂载身份拒绝")
        do { _ = try observeMount(descriptor: -1); fatalError("错误句柄不应可观察") }
        catch { check(true, "无效句柄拒绝") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("writeflow-observation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { _ = rmdir(folder.path) }
        let descriptor = open(folder.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { fatalError("无法打开自有普通测试目录") }
        defer { close(descriptor) }
        let observed = try observeMount(descriptor: descriptor)
        let repeated = try observeMount(descriptor: descriptor)
        check(observed == repeated, "自有普通目录只读观察稳定")
        print("\(count) 项通过；未创建磁盘镜像、未调用 DA 操作、未卸载或访问外部介质。")
    }
}
