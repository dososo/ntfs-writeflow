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
