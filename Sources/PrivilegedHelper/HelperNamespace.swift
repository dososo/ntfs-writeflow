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
        // 仅删除本次凭据与明确的空目录，不递归、不进入卷内容。
        guard unlinkat(folder, "volume", AT_REMOVEDIR) == 0,
              unlinkat(folder, "ticket.json", 0) == 0,
              unlinkat(descriptor, token, AT_REMOVEDIR) == 0 else {
            throw HelperFailure(message: "卷已卸载，但空目录或凭据清理未完成。")
        }
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
        guard fstat(descriptor, &status) == 0, status.st_uid == 0,
              status.st_mode & S_IFMT == S_IFDIR, status.st_mode & 0o022 == 0,
              permissions == nil || status.st_mode & 0o777 == permissions else {
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
