import Foundation
import Darwin
import Security

enum LegacyRuntime {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let libraryPath = "/usr/local/lib/libfuse.2.dylib"
    static let bundlePath = "/Library/Filesystems/macfuse.fs"
    static let maximumLibrarySize: Int64 = 32 * 1024 * 1024

    static func verifySignature(at path: String) throws {
        try verifySignature(at: path, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"3T5GSNBU6W\"")
    }

    static func verifyExecutableSignature(at path: String) throws {
        try verifySignature(at: path, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"ALV8Y54GCY\" and identifier \"com.blteam.ntfsworkbench.legacy\"")
    }

    private static func verifySignature(at path: String, requirement expression: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure(message: "旧后端代码签名、团队或程序标识无效，已停止操作。")
        }
    }

    static func checkInstalled() throws {
        try checkProtectedBundle()
        let source = try openSource()
        defer { close(source) }
        try verifySignature(at: libraryPath)
    }

    static func cachePath(userID: UInt32, token: String) throws -> String {
        guard userID >= 501, userID != UInt32.max, UUID(uuidString: token)?.uuidString == token else {
            throw Failure(message: "旧后端缓存用户或凭据无效。")
        }
        return PrivilegedMountConfiguration.namespace + "/\(userID)/\(token)/runtime/libfuse.2.dylib"
    }

    static func validateCacheDirectory(_ descriptor: Int32, userID: UInt32, token: String) throws {
        let cache = try cachePath(userID: userID, token: token)
        let directoryPath = String(cache.dropLast("/libfuse.2.dylib".count))
        var characters = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &characters) == 0,
              String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == directoryPath else {
            throw Failure(message: "缓存FD不是当前用户凭据的精确runtime目录。")
        }
        let status = try fileStatus(descriptor)
        try verifyProtectedStatus(status, directory: true)
        guard status.st_mode & 0o7777 == 0o700 else { throw Failure(message: "缓存目录必须为root私有0700模式。") }
        try verifyACL(descriptor, empty: true)
        try verifyProtectedPath(directoryPath)
        let current = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Failure(message: "缓存路径已变化。") }
        defer { close(current) }
        let actual = try fileStatus(current)
        guard status.st_dev == actual.st_dev, status.st_ino == actual.st_ino else {
            throw Failure(message: "缓存路径与保留目录FD不一致。")
        }
    }

    static func prepareLibrary(in directoryFD: Int32, userID: UInt32, token: String) throws -> String {
        guard geteuid() == 0 else { throw Failure(message: "仅管理员服务能准备root私有运行时缓存。") }
        try validateCacheDirectory(directoryFD, userID: userID, token: token)
        try checkProtectedBundle()
        let source = try openSource()
        defer { close(source) }
        return try prepareSignedCopy(source: source, in: directoryFD, userID: userID, token: token,
                                     name: "libfuse.2.dylib", verify: verifySignature(at:))
    }

    static func prepareExecutable(in directoryFD: Int32, userID: UInt32, token: String, source: URL) throws -> String {
        guard geteuid() == 0 else { throw Failure(message: "仅管理员服务能准备root私有前端缓存。") }
        try validateCacheDirectory(directoryFD, userID: userID, token: token)
        var characters = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(getpid(), &characters, UInt32(characters.count)) > 0 else {
            throw Failure(message: "无法确认当前管理员服务程序位置。")
        }
        let executable = String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let expected = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("NTFSWriteFlowLegacy").path
        guard source.path == expected else { throw Failure(message: "旧前端源只能是管理员服务同目录的固定程序。") }
        let file = open(expected, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw Failure(message: "无法安全打开同目录旧前端程序。") }
        defer { close(file) }
        return try prepareSignedCopy(source: file, in: directoryFD, userID: userID, token: token,
                                     name: "NTFSWriteFlowLegacy", verify: verifyExecutableSignature(at:))
    }

    private static func prepareSignedCopy(source: Int32, in directoryFD: Int32, userID: UInt32, token: String,
                                          name: String, verify: (String) throws -> Void) throws -> String {
        let file = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure(message: "无法新建专用运行时缓存，保留凭据供安全清理。") }
        defer { close(file) }
        // 源所在目录可能由用户写入。只复制保留FD的内容，绝不从原路径加载。
        try copyContents(source: source, destination: file)
        guard fchmod(file, 0o500) == 0, fsync(file) == 0 else {
            throw Failure(message: "运行时缓存未完成保护与同步，保留凭据供安全清理。")
        }
        let library = try cachePath(userID: userID, token: token)
        let path = String(library.dropLast("libfuse.2.dylib".count)) + name
        try verify(path)
        try validateCacheDirectory(directoryFD, userID: userID, token: token)
        var entry = stat()
        let held = try fileStatus(file)
        guard fstatat(directoryFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_uid == 0, held.st_mode & S_IFMT == S_IFREG, held.st_mode & 0o7777 == 0o500,
              held.st_nlink == 1, entry.st_dev == held.st_dev, entry.st_ino == held.st_ino,
              fsync(directoryFD) == 0 else { throw Failure(message: "运行时缓存身份或持久化核验失败。") }
        try verifyACL(file, empty: true)
        return path
    }

    static func validateSource(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size > 0, status.st_size <= maximumLibrarySize else {
            throw Failure(message: "运行时源必须为不超过32MiB的非空普通文件。")
        }
    }

    static func copyContents(source: Int32, destination: Int32) throws {
        let initial = try fileStatus(source)
        try validateSource(initial)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: Int64 = 0
        while offset < initial.st_size {
            let count = min(buffer.count, Int(initial.st_size - offset))
            var received: Int
            repeat { received = pread(source, &buffer, count, off_t(offset)) } while received < 0 && errno == EINTR
            guard received > 0 else { throw Failure(message: "读取运行时源失败或源被截断。") }
            var written = 0
            while written < received {
                let count = buffer.withUnsafeBytes { write(destination, $0.baseAddress!.advanced(by: written), received - written) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure(message: "写入运行时私有副本失败。") }
                written += count
            }
            offset += Int64(received)
        }
        var extra: UInt8 = 0
        var result: Int
        repeat { result = pread(source, &extra, 1, off_t(offset)) } while result < 0 && errno == EINTR
        guard result == 0 else { throw Failure(message: "复制时运行时源大小已变化或读取失败。") }
    }

    private static func openSource() throws -> Int32 {
        let file = open(libraryPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw Failure(message: "未找到可安全读取的官方macFUSE库，请先自行安装官方运行时。") }
        do { try validateSource(fileStatus(file)); return file }
        catch { close(file); throw error }
    }

    private static func checkProtectedBundle() throws {
        try verifyProtectedPath(bundlePath)
        try verifyProtectedBundle()
        try verifySignature(at: bundlePath)
    }

    private static func fileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Failure(message: "无法读取运行时文件元数据。") }
        return status
    }

    static func verifyProtectedStatus(_ status: stat, directory: Bool) throws {
        guard status.st_uid == 0, status.st_mode & 0o022 == 0,
              status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw Failure(message: "macFUSE依赖必须由root拥有，且不能由普通用户写入或替换。")
        }
    }

    private static func verifyProtectedPath(_ path: String) throws {
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure(message: "无法核验运行时保护路径。") }
        defer { close(parent) }
        for component in path.split(separator: "/") {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure(message: "运行时保护目录缺失或包含符号链接。") }
            do {
                try verifyProtectedStatus(fileStatus(next), directory: true)
                try verifyACL(next, empty: false)
            } catch { close(next); throw error }
            close(parent); parent = next
        }
    }

    private static func verifyProtectedBundle() throws {
        let root = URL(fileURLWithPath: bundlePath)
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
            failure = error; return false
        }) else { throw Failure(message: "无法读取macFUSE依赖束。") }
        for case let url as URL in entries {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { throw Failure(message: "macFUSE依赖条目不可读。") }
            if status.st_mode & S_IFMT == S_IFLNK {
                let resolved = url.resolvingSymlinksInPath().path
                guard status.st_uid == 0, resolved.hasPrefix(bundlePath + "/") else {
                    throw Failure(message: "macFUSE依赖符号链接超出受保护束。")
                }
                continue
            }
            let directory = status.st_mode & S_IFMT == S_IFDIR
            try verifyProtectedStatus(status, directory: directory)
            let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw Failure(message: "macFUSE依赖条目无法安全打开。") }
            defer { close(file) }
            try verifyACL(file, empty: false)
        }
        guard failure == nil else { throw Failure(message: "macFUSE依赖束读取不完整。") }
    }

    static func verifyACL(_ descriptor: Int32, empty: Bool) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT, let security = filesec_init() else { throw Failure(message: "无法读取运行时访问控制。") }
            defer { filesec_free(security) }
            var status = stat(), present: Int32 = -1
            guard fstatx_np(descriptor, &status, security) == 0,
                  filesec_query_property(security, FILESEC_ACL, &present) == 0, present == 0 else {
                throw Failure(message: "无法确认运行时不含额外授权。")
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw Failure(message: "运行时访问控制无效。") }
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, selector, &entry) == 0 {
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
            guard !empty, let entry else { throw Failure(message: "私有运行时缓存必须没有额外ACL。") }
            var tag = ACL_EXTENDED_ALLOW
            guard acl_get_tag_type(entry, &tag) == 0 else { throw Failure(message: "无法核验运行时ACL类型。") }
            if tag == ACL_EXTENDED_DENY { continue }
            var permissions: acl_permset_t?
            guard tag == ACL_EXTENDED_ALLOW, acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw Failure(message: "运行时ACL类型或权限不可确认。")
            }
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                               ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                guard acl_get_perm_np(permissions, permission) == 0 else { throw Failure(message: "运行时ACL授予额外修改权限。") }
            }
        }
    }
}
