import Foundation
import Darwin

// 管理员进程只负责正常卸载；原始设备弹出始终在前台应用进程执行。
extension HelperEject {
    func prepare(handles: [FileHandle]) throws {
        try validateIdentity()
        let mounts = try relatedMounts()
        let paired = try Self.validateHandles(handles, mounts: mounts)
        // 全部句柄先验证，再开始卸载；不以用户提交的路径或可复用设备名执行卸载。
        for (handle, expected) in paired {
            try validateIdentity()
            guard try relatedMounts().contains(expected) else {
                throw HelperFailure(message: "原挂载实例已变化，已停止整盘弹出。")
            }
            let descriptor = handle.fileDescriptor
            try PrivilegedMountEngine.validateUnmountDescriptor(descriptor, expected: expected)
            guard fsync(descriptor) == 0 else {
                throw HelperFailure(message: "同步未完成（\(errno)），未卸载此卷或弹出整盘。")
            }
            guard funmount(descriptor, 0) == 0 else {
                throw HelperFailure(message: "卷未能正常卸载（\(errno)），未弹出整盘；请关闭占用程序后重试。")
            }
        }
        try validateIdentity()
        guard try relatedMounts().isEmpty else {
            throw HelperFailure(message: "同盘仍有已挂载分卷，已停止弹出。")
        }
    }

    static func validateHandles(_ handles: [FileHandle], mounts: [MountedFileSystem]) throws -> [(FileHandle, MountedFileSystem)] {
        guard handles.count == mounts.count, handles.count <= 64,
              Set(mounts.map(\.identity)).count == mounts.count else {
            throw HelperFailure(message: "传入句柄与同盘挂载清单不一致，未请求卸载或弹出。")
        }
        var seen: Set<String> = []
        return try handles.map { handle in
            guard let actual = MountedFileSystemReader.read(descriptor: handle.fileDescriptor),
                  let expected = mounts.first(where: { $0 == actual }),
                  seen.insert(expected.identity).inserted else {
                throw HelperFailure(message: "句柄不是同盘唯一的原挂载实例，未请求卸载或弹出。")
            }
            try PrivilegedMountEngine.validateUnmountDescriptor(handle.fileDescriptor, expected: expected)
            return (handle, expected)
        }
    }

}
