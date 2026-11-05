import Foundation
import Darwin

enum ManagedUnmount {
    struct Operations {
        var verifyDescriptor: (Int32, String) throws -> Void = ManagedUnmount.verifyDescriptor
        var readDescriptor: (Int32) -> MountedFileSystem? = MountedFileSystemReader.read(descriptor:)
        var readPath: (String) -> MountedFileSystem? = MountedFileSystemReader.read(path:)
        var synchronize: (Int32) -> Int32 = { fsync($0) }
        var unmountPath: (String, Int32) -> Int32 = { unmount($0, $1) }
    }

    static func verifyMount(ticket: HelperTicket, expected: MountedFileSystem) throws {
        guard ticket.userID >= 501, ticket.userID != UInt32.max,
              VolumeRecord.validDeviceID(ticket.request.deviceID), ticket.request.mediaRegistryID > 0,
              ticket.request.wholeMediaRegistryID > 0, ticket.request.mediaByteCount > 0,
              PrivilegedMountConfiguration.token(mountPoint: expected.mountPoint, userID: ticket.userID) == ticket.token,
              ["blntfs", "macfuse"].contains(expected.type), expected.ownerID == 0,
              expected.source == "/dev/\(ticket.request.deviceID)",
              !expected.identity.isEmpty, ticket.fileSystemIdentity == expected.identity else {
            throw HelperFailure(message: "旧系统仅允许卸载当前凭据对应的系统专用挂载。")
        }
    }

    static func verifyDescriptor(_ descriptor: Int32, path: String) throws {
        var status = stat()
        var actualPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let flags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptor >= 0, fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              flags >= 0, flags & O_EVTONLY != 0, descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0,
              fcntl(descriptor, F_GETPATH, &actualPath) == 0,
              String(decoding: actualPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path else {
            throw HelperFailure(message: "原事件句柄与精确挂载根目录不一致，已停止卸载。")
        }
    }

    static func synchronizeAndUnmount(descriptor: Int32, expected: MountedFileSystem,
                                      legacyLease: HelperNamespace.UnmountLease?,
                                      validateMedia: () throws -> Void, useLegacy: Bool = false) throws {
        if #available(macOS 26.0, *), !useLegacy {
            try verifyDescriptor(descriptor, path: expected.mountPoint)
            guard MountedFileSystemReader.read(descriptor: descriptor) == expected else {
                throw HelperFailure(message: "原挂载实例已变化，已停止卸载。")
            }
            guard fsync(descriptor) == 0 else { throw failure("同步未完成", errno) }
            guard funmount(descriptor, 0) == 0 else { throw failure("卷未卸载", errno) }
            return
        }
        guard let legacyLease else { throw HelperFailure(message: "旧系统卸载缺少专用目录租约，已停止操作。") }
        try verifyMount(ticket: legacyLease.ticket, expected: expected)
        try withExtendedLifetime(legacyLease) {
            try executeLegacy(descriptor: descriptor, expected: expected,
                validateLease: legacyLease.validate, validateMedia: validateMedia, operations: Operations())
        }
    }

    // 仅限root专用一次性路径；调用方全部事务必须串行。
    // 此方案不承诺抵抗其他root进程绕过仲裁后直接重挂同一路径。
    static func executeLegacy(descriptor: Int32, expected: MountedFileSystem,
                              validateLease: () throws -> Void, validateMedia: () throws -> Void,
                              operations: Operations) throws {
        func validate() throws {
            try validateLease()
            try validateMedia()
            try operations.verifyDescriptor(descriptor, expected.mountPoint)
            guard operations.readDescriptor(descriptor) == expected,
                  operations.readPath(expected.mountPoint) == expected else {
                throw HelperFailure(message: "原句柄和专用路径不再对应同一挂载实例，已停止卸载。")
            }
        }
        try validate()
        guard operations.synchronize(descriptor) == 0 else { throw failure("同步未完成", errno) }
        try validate()
        guard operations.unmountPath(expected.mountPoint, 0) == 0 else { throw failure("卷未卸载", errno) }
    }

    private static func failure(_ action: String, _ code: Int32) -> HelperFailure {
        HelperFailure(message: "\(action)（\(code)）：\(String(cString: strerror(code)))。保留挂载凭据，不强制卸载。")
    }
}
