import Foundation
import Darwin

struct HelperTicket: Codable {
    let userID: UInt32
    let token: String
    let request: PrivilegedMountRequest
    var fileSystemIdentity: String?
}

// 每一级目录均经描述符核验；调用方从不提供文件系统路径。
final class HelperNamespace {
    let userID: UInt32
    let path: String
    let descriptor: Int32

    init(userID: UInt32) throws {
        guard geteuid() == 0, userID >= 501, userID != UInt32.max else {
            throw HelperFailure(message: "后台助手需要系统授权及有效的用户连接。")
        }
        self.userID = userID
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw HelperFailure(message: "无法打开系统根目录。") }
        do {
            for component in ["private", "var", "db"] {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw HelperFailure(message: "无法核验系统数据目录。") }
                do {
                    try Self.verifyDirectory(next, permissions: nil)
                    try Self.verifyACL(next, allowedUser: nil)
                }
                catch { close(next); throw error }
                close(parent)
                parent = next
            }
            let base = try Self.directory(parent: parent, name: "com.blteam.ntfsworkbench.mounts", permissions: 0o755)
            close(parent)
            parent = base
            descriptor = try Self.directory(parent: parent, name: String(userID), permissions: 0o700, allowedUser: userID)
            close(parent)
        } catch { close(parent); throw error }
        path = PrivilegedMountConfiguration.namespace + "/\(userID)"
    }

    deinit { close(descriptor) }

    // 强持有用户目录FD及本次token目录FD；独立打开的flock租约避免重入。
    final class UnmountLease {
        let ticket: HelperTicket
        private let namespace: HelperNamespace
        private let tokenDescriptor: Int32

        fileprivate init(namespace: HelperNamespace, ticket: HelperTicket) throws {
            self.namespace = namespace
            self.ticket = ticket
            let folder = try namespace.tokenDirectory(ticket.token)
            guard flock(folder, LOCK_EX | LOCK_NB) == 0 else {
                close(folder)
                throw HelperFailure(message: "该专用挂载已有卸载事务，已停止重复操作。")
            }
            tokenDescriptor = folder
            try validate()
        }

        deinit { close(tokenDescriptor) }

        func validate() throws {
            try HelperNamespace.verifyDirectory(namespace.descriptor, permissions: 0o700)
            try HelperNamespace.verifyACL(namespace.descriptor, allowedUser: namespace.userID)
            try HelperNamespace.verifyDirectory(tokenDescriptor, permissions: 0o755)
            try HelperNamespace.verifyACL(tokenDescriptor, allowedUser: nil)
            let currentUser = open(namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard currentUser >= 0 else { throw HelperFailure(message: "专用用户目录已变化，已停止卸载。") }
            defer { close(currentUser) }
            var original = stat(), current = stat(), token = stat(), entry = stat()
            guard fstat(namespace.descriptor, &original) == 0, fstat(currentUser, &current) == 0,
                  original.st_dev == current.st_dev, original.st_ino == current.st_ino,
                  fstat(tokenDescriptor, &token) == 0,
                  fstatat(namespace.descriptor, ticket.token, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_mode & S_IFMT == S_IFDIR, token.st_dev == entry.st_dev, token.st_ino == entry.st_ino else {
                throw HelperFailure(message: "专用父目录不再对应保留的原目录，已停止卸载。")
            }
            let saved = try namespace.load(ticket.token)
            try Self.verifyTicket(saved, expected: ticket)
        }

        static func verifyTicket(_ saved: HelperTicket, expected: HelperTicket) throws {
            let before = expected.request, after = saved.request
            guard saved.userID == expected.userID, saved.token == expected.token,
                  saved.fileSystemIdentity == expected.fileSystemIdentity,
                  before.deviceID == after.deviceID, before.mediaRegistryID == after.mediaRegistryID,
                  before.wholeMediaRegistryID == after.wholeMediaRegistryID,
                  before.mediaByteCount == after.mediaByteCount, before.readOnly == after.readOnly else {
                throw HelperFailure(message: "挂载凭据已变化，已停止卸载。")
            }
        }
    }

    func unmountLease(for ticket: HelperTicket) throws -> UnmountLease {
        guard ticket.userID == userID else { throw HelperFailure(message: "挂载凭据不属于当前连接用户。") }
        return try UnmountLease(namespace: self, ticket: ticket)
    }

    func runtimeDirectory(for ticket: HelperTicket) throws -> Int32 {
        guard ticket.userID == userID else { throw HelperFailure(message: "运行时凭据不属于当前连接用户。") }
        try UnmountLease.verifyTicket(load(ticket.token), expected: ticket)
        let folder = try tokenDirectory(ticket.token)
        defer { close(folder) }
        return try Self.directory(parent: folder, name: "runtime", permissions: 0o700)
    }

    func mediaLease(for request: PrivilegedMountRequest) throws -> FileHandle {
        guard geteuid() == 0 else { throw HelperFailure(message: "媒体租约需要管理员服务。") }
        let name = try Self.mediaLockName(for: request)
        let base = try protectedBaseDirectory()
        defer { close(base) }
        let folder = try Self.directory(parent: base, name: "media-leases", permissions: 0o700)
        defer { close(folder) }
        var file = openat(folder, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let created = file >= 0
        if file < 0 && errno == EEXIST { file = openat(folder, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard file >= 0 else { throw HelperFailure(message: "无法打开固定媒体租约文件。") }
        do {
            if created {
                guard fchmod(file, 0o600) == 0 else { throw HelperFailure(message: "无法设置媒体租约权限。") }
                try Self.setACL(file, allowedUser: nil)
            }
            let original = try Self.fileStatus(file)
            try Self.verifyMediaLockMetadata(original)
            try Self.verifyACL(file, allowedUser: nil)
            var entry = stat()
            guard fstatat(folder, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_dev == original.st_dev, entry.st_ino == original.st_ino else {
                throw HelperFailure(message: "媒体租约文件身份已变化。")
            }
            guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
                throw HelperFailure(message: "同一介质仍由现存后端持有，拒绝重复启动写入。")
            }
            // 不删除或截断锁文件，防止新inode绕过仍由子进程持有的锁。
            return FileHandle(fileDescriptor: file, closeOnDealloc: true)
        } catch { close(file); throw error }
    }

    private func protectedBaseDirectory() throws -> Int32 {
        let base = openat(descriptor, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw HelperFailure(message: "无法打开受保护媒体租约父目录。") }
        do {
            try Self.verifyDirectory(base, permissions: 0o755)
            try Self.verifyACL(base, allowedUser: nil)
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard fcntl(base, F_GETPATH, &path) == 0,
                  String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == PrivilegedMountConfiguration.namespace else {
                throw HelperFailure(message: "媒体租约父目录不再属于固定系统命名空间。")
            }
            return base
        } catch { close(base); throw error }
    }

    static func bridgeNamespaceUserID(_ name: String) throws -> UInt32? {
        if name == "media-leases" { return nil }
        guard let userID = UInt32(name), userID >= 501, userID != .max, String(userID) == name else {
            throw HelperFailure(message: "系统挂载命名空间包含未知条目，已停止新挂载。")
        }
        return userID
    }

    static func bridgeTokens(from entries: Set<String>) throws -> [String] {
        for token in entries { try validateToken(token) }
        return entries.sorted()
    }

    static func requireNoPendingBridgeTicket(_ ticket: HelperTicket, wholeMediaRegistryID: UInt64) throws {
        _ = try HelperCommand.systemMountArguments(ticket.request, userID: ticket.userID, token: ticket.token)
        guard wholeMediaRegistryID > 0, ticket.request.wholeMediaRegistryID > 0, ticket.request.mediaByteCount > 0,
              ticket.fileSystemIdentity != "" else { throw HelperFailure(message: "既存挂载凭据异常，已停止新挂载。") }
        guard ticket.request.wholeMediaRegistryID != wholeMediaRegistryID || ticket.fileSystemIdentity != nil else {
            throw HelperFailure(message: "同一整盘存在尚未确认结果的挂载票据，已停止重复操作；请先刷新并由维护者核验，不能按当前未显示挂载自动清理。")
        }
    }

    func requireNoPendingBridgeMount(for request: PrivilegedMountRequest) throws {
        let base = try protectedBaseDirectory()
        defer { close(base) }
        for name in try Self.directoryEntries(base).sorted() {
            guard let owner = try Self.bridgeNamespaceUserID(name) else {
                let locks = try Self.directory(parent: base, name: name, permissions: 0o700, create: false)
                close(locks)
                continue
            }
            let area = try HelperNamespace(userID: owner)
            for token in try Self.bridgeTokens(from: Self.directoryEntries(area.descriptor)) {
                let folder = try area.tokenDirectory(token)
                defer { close(folder) }
                let entries = try Self.directoryEntries(folder)
                guard entries.contains("ticket.json"), entries.contains("volume"),
                      entries.isSubset(of: ["ticket.json", "volume", "runtime"]) else {
                    throw HelperFailure(message: "既存凭据目录包含未知或缺失条目，已停止新挂载。")
                }
                try Self.requireNoPendingBridgeTicket(area.load(token), wholeMediaRegistryID: request.wholeMediaRegistryID)
            }
        }
    }

    static func mediaLockName(for request: PrivilegedMountRequest) throws -> String {
        guard request.mediaRegistryID > 0, request.wholeMediaRegistryID > 0,
              request.mediaByteCount > 0, VolumeRecord.validDeviceID(request.deviceID) else {
            throw HelperFailure(message: "媒体租约请求无效。")
        }
        return "\(request.wholeMediaRegistryID).lock"
    }

    static func verifyMediaLockMetadata(_ status: stat) throws {
        guard status.st_uid == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o7777 == 0o600, status.st_nlink == 1 else {
            throw HelperFailure(message: "媒体租约必须为root单链接0600普通文件。")
        }
    }

    func create(_ request: PrivilegedMountRequest) throws -> HelperTicket {
        let ticket = HelperTicket(userID: userID, token: UUID().uuidString, request: request)
        let folder = try tokenDirectory(ticket.token, create: true)
        defer { close(folder) }
        let mount = try Self.directory(parent: folder, name: "volume", permissions: 0o755)
        close(mount)
        try save(ticket)
        return ticket
    }

    func mountPoint(_ token: String) throws -> String {
        try Self.validateToken(token)
        return path + "/\(token)/volume"
    }

    func load(_ token: String) throws -> HelperTicket {
        let folder = try tokenDirectory(token)
        defer { close(folder) }
        let file = openat(folder, "ticket.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw HelperFailure(message: "挂载凭据不存在。") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard fstat(file, &status) == 0, status.st_uid == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == 0o600, status.st_nlink == 1, status.st_size <= 8192 else {
            throw HelperFailure(message: "挂载凭据权限或大小无效。")
        }
        try Self.verifyACL(file, allowedUser: nil)
        let ticket = try JSONDecoder().decode(HelperTicket.self, from: handle.readToEnd() ?? Data())
        guard ticket.userID == userID, ticket.token == token else {
            throw HelperFailure(message: "挂载凭据不属于当前连接用户。")
        }
        return ticket
    }

    func save(_ ticket: HelperTicket) throws {
        let folder = try tokenDirectory(ticket.token)
        defer { close(folder) }
        let temporary = "ticket-\(UUID().uuidString).tmp"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw HelperFailure(message: "无法保存挂载凭据。") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        do {
            try Self.setACL(file, allowedUser: nil)
            try handle.write(contentsOf: JSONEncoder().encode(ticket))
            try handle.synchronize()
            guard renameat(folder, temporary, folder, "ticket.json") == 0, fsync(folder) == 0 else {
                throw HelperFailure(message: "挂载凭据未能可靠保存。")
            }
        } catch { _ = unlinkat(folder, temporary, 0); throw error }
    }

    func tokens() throws -> [String] {
        // 路径链由 root 拥有且不授予用户写入，列表内容仍逐个严格验证。
        try FileManager.default.contentsOfDirectory(atPath: path).filter {
            UUID(uuidString: $0)?.uuidString == $0
        }
    }

    func discardUnmounted(_ token: String) throws {
        let mountPoint = try mountPoint(token)
        guard MountedFileSystemReader.read(path: mountPoint) == nil else {
            throw HelperFailure(message: "仍有挂载，保留挂载凭据。")
        }
        let folder = try tokenDirectory(token)
        defer { close(folder) }
        try Self.removeRuntime(parent: folder)
        // 仅删除本次凭据与明确的空目录，不递归、不进入卷内容。
        guard unlinkat(folder, "volume", AT_REMOVEDIR) == 0,
              unlinkat(folder, "ticket.json", 0) == 0,
              unlinkat(descriptor, token, AT_REMOVEDIR) == 0 else {
            throw HelperFailure(message: "卷已卸载，但空目录或凭据清理未完成。")
        }
    }

    // 先完整核验已知缓存；未知条目或异常权限均保留挂载凭据。
    static func removeRuntime(parent: Int32, inspect: (Int32) throws -> stat = fileStatus) throws {
        let runtime = openat(parent, "runtime", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runtime >= 0 else {
            if errno == ENOENT { return }
            throw HelperFailure(message: "无法核验专用运行时目录，保留挂载凭据。")
        }
        defer { close(runtime) }
        try verifyDirectoryStatus(inspect(runtime), permissions: 0o700)
        try verifyACL(runtime, allowedUser: nil)
        let entries = try directoryEntries(runtime)
        guard entries.isSubset(of: ["libfuse.2.dylib", "NTFSWriteFlowLegacy", "NTFSWriteFlowMountHelper"]) else {
            throw HelperFailure(message: "运行时目录包含未知条目，保留挂载凭据。")
        }
        var files: [Int32] = []
        defer { for file in files { close(file) } }
        for name in entries.sorted() {
            let file = openat(runtime, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw HelperFailure(message: "无法核验运行时缓存文件，保留挂载凭据。") }
            files.append(file)
            let status = try inspect(file)
            guard status.st_uid == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                  [mode_t(0o500), mode_t(0o600)].contains(status.st_mode & 0o7777) else {
                throw HelperFailure(message: "运行时缓存文件权限或链接数异常，保留挂载凭据。")
            }
            try verifyACL(file, allowedUser: nil)
        }
        // 固定文件全部核验成功后才删除，异常时不先损失另一缓存。
        for name in entries.sorted() {
            guard unlinkat(runtime, name, 0) == 0 else {
                throw HelperFailure(message: "运行时缓存文件未清理，保留挂载凭据。")
            }
        }
        guard unlinkat(parent, "runtime", AT_REMOVEDIR) == 0 else {
            throw HelperFailure(message: "运行时目录未清空，保留挂载凭据。")
        }
    }

    private static func fileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw HelperFailure(message: "无法读取缓存元数据，保留挂载凭据。") }
        return status
    }

    private static func directoryEntries(_ descriptor: Int32) throws -> Set<String> {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw HelperFailure(message: "无法读取缓存目录，保留挂载凭据。") }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw HelperFailure(message: "无法读取缓存目录，保留挂载凭据。")
        }
        defer { closedir(directory) }
        var names: Set<String> = []
        errno = 0
        while let entry = readdir(directory) {
            var field = entry.pointee.d_name
            let name = withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.insert(name) }
        }
        guard errno == 0 else { throw HelperFailure(message: "缓存目录读取不完整，保留挂载凭据。") }
        return names
    }

    private func tokenDirectory(_ token: String, create: Bool = false) throws -> Int32 {
        try Self.validateToken(token)
        return try Self.directory(parent: descriptor, name: token, permissions: 0o755, create: create)
    }

    private static func validateToken(_ token: String) throws {
        guard UUID(uuidString: token)?.uuidString == token else {
            throw HelperFailure(message: "挂载凭据标识无效。")
        }
    }

    private static func directory(parent: Int32, name: String, permissions: mode_t,
                                  allowedUser: UInt32? = nil, create: Bool = true) throws -> Int32 {
        var created = false
        if create {
            if mkdirat(parent, name, permissions) == 0 { created = true }
            else if errno != EEXIST { throw HelperFailure(message: "无法创建专用挂载目录。") }
        }
        let file = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw HelperFailure(message: "无法打开专用挂载目录。") }
        do {
            // 守护进程 umask 为 077；先在不可访问状态创建，再设置固定模式和 ACL。
            if created, fchmod(file, permissions) != 0 { throw HelperFailure(message: "无法设置专用目录权限。") }
            try verifyDirectory(file, permissions: permissions)
            if created { try setACL(file, allowedUser: allowedUser) }
            try verifyACL(file, allowedUser: allowedUser)
            return file
        } catch { close(file); throw error }
    }

    private static func verifyDirectory(_ descriptor: Int32, permissions: mode_t?) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw HelperFailure(message: "目录必须由系统拥有，且不可由其他用户替换。")
        }
        try verifyDirectoryStatus(status, permissions: permissions)
    }

    static func verifyDirectoryStatus(_ status: stat, permissions: mode_t?) throws {
        guard status.st_uid == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_mode & 0o022 == 0,
              permissions == nil || status.st_mode & 0o7777 == permissions else {
            throw HelperFailure(message: "目录必须由系统拥有，且不可由其他用户替换。")
        }
    }

    static func makeACL(_ userID: UInt32?) throws -> acl_t {
        var acl = acl_init(1)
        guard acl != nil else { throw HelperFailure(message: "无法建立目录访问控制。") }
        do {
            if let userID {
                var uuid = UUID().uuid
                guard mbr_uid_to_uuid(userID, &uuid) == 0 else { throw HelperFailure(message: "无法解析连接用户身份。") }
                var entry: acl_entry_t?
                guard acl_create_entry(&acl, &entry) == 0, let entry,
                      acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
                      acl_set_qualifier(entry, &uuid) == 0 else { throw HelperFailure(message: "无法建立用户访问条目。") }
                var permissions: acl_permset_t?
                guard acl_get_permset(entry, &permissions) == 0, let permissions,
                      acl_clear_perms(permissions) == 0 else { throw HelperFailure(message: "无法设置目录访问权限。") }
                for permission in [ACL_LIST_DIRECTORY, ACL_SEARCH, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY] {
                    guard acl_add_perm(permissions, permission) == 0 else { throw HelperFailure(message: "无法设置目录访问权限。") }
                }
            }
            return acl!
        } catch { if let acl { acl_free(UnsafeMutableRawPointer(acl)) }; throw error }
    }

    static func setACL(_ descriptor: Int32, allowedUser: UInt32?) throws {
        let acl = try makeACL(allowedUser)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw HelperFailure(message: "无法设置专用目录访问控制。") }
    }

    static func verifyACL(_ descriptor: Int32, allowedUser: UInt32?) throws {
        let expected = try makeACL(allowedUser)
        defer { acl_free(UnsafeMutableRawPointer(expected)) }
        guard let actual = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // APFS 对不存在的扩展 ACL 返回 ENOENT。独立读取安全属性明确确认不存在，
            // 才能满足空 ACL 策略；权限、无效描述符及其他读取错误仍全部拒绝。
            guard errno == ENOENT, allowedUser == nil, let security = filesec_init() else {
                throw HelperFailure(message: "无法读取目录访问控制。")
            }
            defer { filesec_free(security) }
            var status = stat()
            var present: Int32 = -1
            guard fstatx_np(descriptor, &status, security) == 0,
                  filesec_query_property(security, FILESEC_ACL, &present) == 0, present == 0 else {
                throw HelperFailure(message: "无法确认目录不含额外访问授权。")
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(actual)) }
        guard let first = acl_to_text(expected, nil) else { throw HelperFailure(message: "无法核对目录访问控制。") }
        defer { acl_free(first) }
        guard let second = acl_to_text(actual, nil) else { throw HelperFailure(message: "无法核对目录访问控制。") }
        defer { acl_free(second) }
        guard strcmp(first, second) == 0 else { throw HelperFailure(message: "目录访问控制不符合当前用户隔离要求。") }
    }
}
