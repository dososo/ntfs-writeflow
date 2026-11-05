import Foundation

@main enum ManagedMountDiscoveryTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        precondition(StorageBackend.select(major: 12, minor: 7) == nil)
        precondition(StorageBackend.select(major: 13, minor: 0) == .macFUSE)
        precondition(StorageBackend.select(major: 15, minor: 3) == .macFUSE)
        precondition(StorageBackend.select(major: 15, minor: 4) == .fsKit)
        precondition(StorageBackend.select(major: 26, minor: 0) == .fsKit)
        precondition(!VolumeRecord.validDeviceID("disk1\n"))
        let token = UUID().uuidString
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        func mount(_ type: String = "macfuse", source: String = "/dev/disk99s1",
                   at: String? = nil, owner: UInt32 = 0) -> MountedFileSystem {
            MountedFileSystem(type: type, source: source, mountPoint: at ?? path,
                identity: "42:7", ownerID: owner, isReadOnly: false)
        }
        let legacy = mount()
        check(try MountedFileSystemReader.managedMount(in: [legacy], deviceID: "disk99s1", userID: 501) == legacy)
        check(try MountedFileSystemReader.managedMount(in: [mount("blntfs")], deviceID: "disk99s1", userID: 501) != nil)
        for invalid in [mount("macfuse_OTHER"), mount(source: "/dev/disk99s2"), mount(at: "/Volumes/其他卷"),
                        mount(owner: 501), mount(at: path.replacingOccurrences(of: "/501/", with: "/502/")),
                        mount(at: path.replacingOccurrences(of: token, with: "../其他"))] {
            check(try MountedFileSystemReader.managedMount(in: [invalid], deviceID: "disk99s1", userID: 501) == nil)
        }
        do {
            _ = try MountedFileSystemReader.managedMount(in: [legacy, legacy], deviceID: "disk99s1", userID: 501)
            fatalError("重复挂载不能选取其中一个后继续操作")
        } catch { }
        print("通过：旧系统后端选择、非法设备名、兼容挂载来源与私有路径、跨用户和重复映射拒绝。未访问磁盘。")
    }
}
