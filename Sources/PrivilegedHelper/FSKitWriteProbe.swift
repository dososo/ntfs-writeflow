import Foundation
import Darwin

// 只从票据专用验签副本运行；根FD经stdin继承，不接收调用方路径。
enum FSKitWriteProbe {
    static let mode = "--internal-fskit-write-probe"

    static func arguments(userID: UInt32, token: String, preparing: Bool) throws -> [String] {
        guard userID >= 501, userID != UInt32.max,
              UUID(uuidString: token)?.uuidString == token else {
            throw HelperFailure(message: "内部写入检查用户或凭据无效。")
        }
        return [mode, String(userID), token, preparing ? "prepare" : "status"]
    }

    static func parse(_ arguments: [String]) throws -> (UInt32, String, Bool) {
        guard arguments.count == 4, arguments[0] == mode,
              let userID = UInt32(arguments[1]), String(userID) == arguments[1],
              ["prepare", "status"].contains(arguments[3]) else {
            throw HelperFailure(message: "内部写入检查参数无效。")
        }
        let preparing = arguments[3] == "prepare"
        _ = try self.arguments(userID: userID, token: arguments[2], preparing: preparing)
        return (userID, arguments[2], preparing)
    }

    static func execute(_ arguments: [String]) throws -> Data {
        guard getuid() == 0, geteuid() == 0 else {
            throw HelperFailure(message: "内部写入检查仅允许管理员服务启动。")
        }
        let (userID, token, preparing) = try parse(arguments)
        try LegacyRuntime.verifyCurrentMountHelper(userID: userID, token: token)
        let namespace = try HelperNamespace(userID: userID)
        let ticket = try namespace.load(token)
        guard FSKitWriteReadiness.requires(backend: ticket.backend ?? .fsKit, readOnly: ticket.request.readOnly),
              ticket.fileSystemIdentity?.isEmpty == false else {
            throw HelperFailure(message: "原凭据不适用旧系统写入检查。")
        }
        // 子进程即使超时仍保留租约；其退出前不得并发卸载或删除凭据。
        let lease = try namespace.unmountLease(for: ticket)
        return try withExtendedLifetime(lease) {
            guard fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC) == 0,
                  let expected = MountedFileSystemReader.read(descriptor: STDIN_FILENO), expected.type == "blntfs",
                  PrivilegedMountEngine.matchesOwnedMount(ticket, path: try namespace.mountPoint(token), mounted: expected) else {
                throw HelperFailure(message: "继承的根句柄不对应本次挂载。")
            }
            func validate() throws {
                try lease.validate()
                try PrivilegedMountEngine.validateUnmountDescriptor(STDIN_FILENO, expected: expected)
                try HelperMedia(ticket.request).validate(ticket.request)
                guard MountedFileSystemReader.read(path: expected.mountPoint) == expected else {
                    throw HelperFailure(message: "写入检查期间挂载实例已变化。")
                }
            }
            try validate()
            let name = try preparing ? FSKitWriteReadiness.prepareName(token: token) : FSKitWriteReadiness.statusName(token: token)
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = name.withCString { name in
                fgetxattr(STDIN_FILENO, name, &bytes, bytes.count, 0, 0)
            }
            guard count > 0, count <= bytes.count else {
                let failure = count < 0 ? errno : EIO
                throw HelperFailure(message: "扩展尚未确认内部可写（\(failure)）；未报告挂载成功，请正常卸载后重试。")
            }
            let data = Data(bytes.prefix(count))
            try FSKitWriteReadiness.validate(data, token: token, mediaID: ticket.request.mediaRegistryID)
            try validate()
            return data
        }
    }
}
