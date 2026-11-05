import Foundation
import Darwin

enum MountedFileSystemReader {
    static func read(path: String) -> MountedFileSystem? {
        var status = statfs()
        guard statfs(path, &status) == 0 else { return nil }
        let result = decode(status)
        // statfs 也可能返回父目录所在卷；只接受精确挂载根目录。
        return result.mountPoint == path ? result : nil
    }

    static func read(descriptor: Int32) -> MountedFileSystem? {
        var status = statfs()
        guard fstatfs(descriptor, &status) == 0 else { return nil }
        return decode(status)
    }

    // 兼容FUSE卷可能不出现在diskutil的MountPoint；仅接纳本用户root专用路径。
    static func managedMount(in mounts: [MountedFileSystem], deviceID: String, userID: UInt32) throws -> MountedFileSystem? {
        let candidates = mounts.filter {
            $0.isWriteFlow && $0.source == "/dev/\(deviceID)" && $0.ownerID == 0
                && PrivilegedMountConfiguration.token(mountPoint: $0.mountPoint, userID: userID) != nil
        }
        guard candidates.count <= 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY),
                userInfo: [NSLocalizedDescriptionKey: "同一设备存在多个受管挂载，已停止操作。"])
        }
        return candidates.first
    }

    static func deviceMounts(_ deviceID: String) throws -> [MountedFileSystem] {
        var values: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&values, MNT_NOWAIT)
        guard count > 0, let values else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        defer { free(values) }
        return (0..<Int(count)).map { decode(values[$0]) }.filter { $0.source == "/dev/\(deviceID)" }
    }

    static func managedMount(deviceID: String, userID: UInt32) throws -> MountedFileSystem? {
        try managedMount(in: deviceMounts(deviceID), deviceID: deviceID, userID: userID)
    }

    private static func decode(_ value: statfs) -> MountedFileSystem {
        var value = value
        return MountedFileSystem(type: string(&value.f_fstypename), source: string(&value.f_mntfromname),
            mountPoint: string(&value.f_mntonname), identity: "\(value.f_fsid.val.0):\(value.f_fsid.val.1)",
            ownerID: value.f_owner, isReadOnly: value.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
