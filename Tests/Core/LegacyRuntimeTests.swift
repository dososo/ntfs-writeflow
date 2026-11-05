import Foundation
import Darwin
import Security

@main enum LegacyRuntimeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("用法：运行时验证 <官方macFUSE展开Payload目录> <本应用已签名助手文件>\n前置：只读展开官方安装包，并准备本应用团队签名有效、标识不是legacy的助手；不安装或加载运行时。\n", stderr)
            exit(EX_USAGE)
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let ownHelper = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: fixture + "/usr/local/lib/libfuse.2.dylib"),
              FileManager.default.fileExists(atPath: fixture + "/Library/Filesystems/macfuse.fs"),
              FileManager.default.fileExists(atPath: ownHelper) else {
            fputs("缺少测试前置：请显式提供含官方库与文件系统束的Payload目录，以及真实已签名的本应用助手文件。\n", stderr)
            exit(EX_NOINPUT)
        }
        var checks: [String] = []
        func rejected(_ name: String, _ work: () throws -> Void) {
            do { try work(); fatalError(name) }
            catch is LegacyRuntime.Failure { checks.append(name) }
            catch { fatalError("出现非预期错误：\(error)") }
        }
        let library = fixture + "/usr/local/lib/libfuse.2.dylib"
        let bundle = fixture + "/Library/Filesystems/macfuse.fs"
        try LegacyRuntime.verifySignature(at: library)
        checks.append("官方展开库严格校验所有架构与固定Team通过，不加载或安装")
        try LegacyRuntime.verifySignature(at: bundle)
        checks.append("官方展开文件系统束及嵌套代码签名通过")
        rejected("Apple签名程序不是指定macFUSE团队") { try LegacyRuntime.verifySignature(at: "/bin/ls") }
        rejected("macFUSE官方库不能冒充本应用前端团队与标识") { try LegacyRuntime.verifyExecutableSignature(at: library) }
        var ownCode: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: ownHelper) as CFURL, [], &ownCode) == errSecSuccess,
              let ownCode,
              SecStaticCodeCheckValidity(ownCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopySigningInformation(ownCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let ownMetadata = information as NSDictionary?,
              ownMetadata[kSecCodeInfoTeamIdentifier] as? String == "ALV8Y54GCY",
              ownMetadata[kSecCodeInfoIdentifier] as? String != "com.blteam.ntfsworkbench.legacy" else {
            fputs("测试前置无效：助手必须有本应用团队的完整有效签名，且标识不能为legacy；不能以缺失或假签名代替错误标识反例。\n", stderr)
            exit(EX_DATAERR)
        }
        rejected("同一应用团队的其他标识也不能冒充legacy程序") { try LegacyRuntime.verifyExecutableSignature(at: ownHelper) }
        rejected("缺失路径不能冒充有效运行时") { try LegacyRuntime.verifySignature(at: fixture + "/不存在") }
        let temporary = "/private/tmp/WriteFlow-运行时验证-\(UUID().uuidString)"
        precondition(mkdir(temporary, 0o700) == 0)
        defer { precondition(rmdir(temporary) == 0) }
        let directory = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(directory >= 0)
        defer { close(directory) }
        func setACL(_ tag: acl_tag_t, _ permission: acl_perm_t) throws {
            var acl = acl_init(1)
            precondition(acl != nil)
            defer { acl_free(UnsafeMutableRawPointer(acl!)) }
            var entry: acl_entry_t?
            precondition(acl_create_entry(&acl, &entry) == 0)
            var qualifier = UUID().uuid
            precondition(acl_set_tag_type(entry!, tag) == 0 && acl_set_qualifier(entry!, &qualifier) == 0)
            var permissions: acl_permset_t?
            precondition(acl_get_permset(entry!, &permissions) == 0)
            precondition(acl_clear_perms(permissions!) == 0 && acl_add_perm(permissions!, permission) == 0)
            precondition(acl_set_fd_np(directory, acl, ACL_TYPE_EXTENDED) == 0)
        }
        func clearACL() {
            let acl = acl_init(0)
            precondition(acl != nil)
            precondition(acl_set_fd_np(directory, acl, ACL_TYPE_EXTENDED) == 0)
            acl_free(UnsafeMutableRawPointer(acl!))
        }
        defer { clearACL() }
        try setACL(ACL_EXTENDED_DENY, ACL_DELETE)
        try LegacyRuntime.verifyACL(directory, empty: false)
        checks.append("受保护依赖路径允许合法deny-delete ACL")
        rejected("root私有缓存不接受非空deny ACL") { try LegacyRuntime.verifyACL(directory, empty: true) }
        try setACL(ACL_EXTENDED_ALLOW, ACL_WRITE_DATA)
        rejected("依赖路径允许写入的ACL必须拒绝") { try LegacyRuntime.verifyACL(directory, empty: false) }
        clearACL()
        try LegacyRuntime.verifyACL(directory, empty: true)
        checks.append("真实普通目录空ACL读取通过；不冒充root保护目录")
        if geteuid() != 0 {
            rejected("普通用户不能准备root私有库缓存") {
                _ = try LegacyRuntime.prepareLibrary(in: directory, userID: geteuid(), token: UUID().uuidString)
            }
            rejected("普通用户不能准备root私有前端缓存") {
                _ = try LegacyRuntime.prepareExecutable(in: directory, userID: geteuid(), token: UUID().uuidString,
                    source: URL(fileURLWithPath: library))
            }
        }
        for (uid, token): (UInt32, String) in [(0, UUID().uuidString), (501, "../旧凭据"), (.max, UUID().uuidString)] {
            rejected("缓存路径拒绝非法用户或token") { _ = try LegacyRuntime.cachePath(userID: uid, token: token) }
        }
        let token = UUID().uuidString
        let expected = PrivilegedMountConfiguration.namespace + "/501/\(token)/runtime/libfuse.2.dylib"
        let actualCache = try LegacyRuntime.cachePath(userID: 501, token: token)
        precondition(actualCache == expected)
        checks.append("缓存路径仅由可信用户和规范UUID固定派生")
        var status = stat()
        status.st_mode = S_IFREG | 0o600; status.st_size = 64; status.st_nlink = 1
        try LegacyRuntime.validateSource(status)
        checks.append("源文件无需信任/usr/local所有权，实际执行内容由私有副本签名决定")
        for (mode, size): (mode_t, Int64) in [(S_IFDIR | 0o700, 64), (S_IFREG | 0o600, 0),
                                            (S_IFREG | 0o600, 33 * 1024 * 1024)] {
            status.st_mode = mode; status.st_size = size
            rejected("源类型、空文件或超限均拒绝") { try LegacyRuntime.validateSource(status) }
        }
        status.st_uid = 0; status.st_mode = S_IFDIR | 0o755
        try LegacyRuntime.verifyProtectedStatus(status, directory: true)
        checks.append("构造root保护元数据通过；不是实际root验收")
        for (owner, mode): (UInt32, mode_t) in [(501, S_IFDIR | 0o755), (0, S_IFDIR | 0o775), (0, S_IFREG | 0o755)] {
            status.st_uid = owner; status.st_mode = mode
            rejected("非root、普通用户可写或非目录的保护链拒绝") {
                try LegacyRuntime.verifyProtectedStatus(status, directory: true)
            }
        }
        let copyPath = temporary + "/只复制不加载.dylib"
        let output = open(copyPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        let input = open(library, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        precondition(input >= 0 && output >= 0)
        defer { close(input); close(output); precondition(unlink(copyPath) == 0) }
        rejected("源FD读取错误立即拒绝") { try LegacyRuntime.copyContents(source: -1, destination: output) }
        rejected("私有副本写入错误立即拒绝") { try LegacyRuntime.copyContents(source: input, destination: -1) }
        try LegacyRuntime.copyContents(source: input, destination: output)
        let copiedBytes = try Data(contentsOf: URL(fileURLWithPath: copyPath))
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: library))
        precondition(copiedBytes == sourceBytes)
        try LegacyRuntime.verifySignature(at: copyPath)
        checks.append("持有源FD复制官方库后内容与签名一致；仅普通用户测试副本，不加载")
        let oversized = temporary + "/超限稀疏文件"
        let largeFD = open(oversized, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        precondition(largeFD >= 0 && ftruncate(largeFD, off_t(LegacyRuntime.maximumLibrarySize + 1)) == 0)
        defer { close(largeFD); precondition(unlink(oversized) == 0) }
        rejected("真实超限普通文件在读取内容前拒绝") { try LegacyRuntime.copyContents(source: largeFD, destination: output) }
        let changed = temporary + "/篡改副本.dylib"
        try FileManager.default.copyItem(atPath: library, toPath: changed)
        defer { precondition(unlink(changed) == 0) }
        let mutable = open(changed, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        precondition(mutable >= 0)
        var header = [UInt8](repeating: 0, count: 64)
        precondition(pread(mutable, &header, header.count, 0) == header.count)
        let firstSlice = header[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let offset = off_t(firstSlice) + 4096
        var byte: UInt8 = 0
        precondition(pread(mutable, &byte, 1, offset) == 1)
        byte ^= 1
        precondition(pwrite(mutable, &byte, 1, offset) == 1)
        close(mutable)
        rejected("篡改官方通用库的首个架构后严格签名拒绝") { try LegacyRuntime.verifySignature(at: changed) }
        rejected("当前自有普通目录不能冒充root私有runtime链") {
            try LegacyRuntime.validateCacheDirectory(directory, userID: 501, token: token)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["结果": "通过", "数量": checks.count,
            "检查": checks, "边界": "官方只读展开制品签名、仅自建篡改副本、构造元数据和普通用户拒绝。未安装、未加载库、未启用第三方运行时、未执行root缓存或设备操作。"],
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
