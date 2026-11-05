import Foundation
import Darwin

@main enum LegacyReceiptTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("用法：回执验证 <真实C writer产物前缀>\n前置：同一前缀须有.pending、.status0、.status74、.syncfail四个普通文件；可由独立运行脚本重新生成。\n", stderr)
            exit(EX_USAGE)
        }
        let fixturePrefix = CommandLine.arguments[1]
        for suffix in ["pending", "status0", "status74", "syncfail"] {
            guard FileManager.default.fileExists(atPath: fixturePrefix + "." + suffix) else {
                fputs("缺少C回执测试产物：\(fixturePrefix).\(suffix)\n", stderr)
                exit(EX_NOINPUT)
            }
        }
        var checks: [String] = []
        func rejected(_ name: String, _ work: () throws -> Void) {
            do { try work(); fatalError(name) }
            catch is HelperFailure { checks.append(name) }
            catch { fatalError("出现非预期错误：\(error)") }
        }
        let path = "/private/tmp/WriteFlow-回执验证-\(UUID().uuidString)"
        let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        precondition(descriptor >= 0)
        defer { close(descriptor); precondition(unlink(path) == 0) }
        let token = UUID().uuidString
        let original: [String: Any] = ["version": 1, "userID": 501, "wholeMediaRegistryID": 122,
                                       "token": token, "status": 0]
        func replace(_ values: [String: Any], header: UInt8 = 1) throws {
            var data = Data([header]); data.append(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]))
            precondition(ftruncate(descriptor, 0) == 0)
            let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            precondition(written == data.count)
        }
        let empty = try LegacyReceipt.read(from: descriptor)
        precondition(empty == nil)
        checks.append("新建0长度锁文件仅返回nil，由启动调用方决定是否允许")
        try replace(original)
        precondition(lseek(descriptor, 7, SEEK_SET) == 7)
        let receipt = try LegacyReceipt.read(from: descriptor)!
        try receipt.requireClean(wholeMediaRegistryID: 122, userID: 501, token: token)
        checks.append("完整已提交状态0回执匹配整盘、用户与token")
        precondition(lseek(descriptor, 0, SEEK_CUR) == 7)
        checks.append("pread读取不改变共享FD偏移")
        try receipt.requireClean(wholeMediaRegistryID: 122)
        checks.append("整盘历史检查可省略用户和token，但仍要求状态0及相同wholeID")
        rejected("旧token回执不能证明本次挂载关闭干净") {
            try receipt.requireClean(wholeMediaRegistryID: 122, userID: 501, token: UUID().uuidString)
        }
        rejected("其他用户回执不能证明当前用户关闭干净") {
            try receipt.requireClean(wholeMediaRegistryID: 122, userID: 502)
        }
        rejected("另一整盘的状态0回执也拒绝") { try receipt.requireClean(wholeMediaRegistryID: 123) }
        for header: UInt8 in [0, 2, 255] {
            try replace(original, header: header)
            rejected("进行中或未知提交头不能视为干净") { _ = try LegacyReceipt.read(from: descriptor) }
        }
        precondition(ftruncate(descriptor, 1) == 0)
        var committed: UInt8 = 1
        precondition(pwrite(descriptor, &committed, 1, 0) == 1)
        rejected("只有提交头而无正文不能视为干净") { _ = try LegacyReceipt.read(from: descriptor) }
        var partial = Data([1]); partial.append(Data("{\"version\":1".utf8))
        precondition(ftruncate(descriptor, 0) == 0)
        precondition(partial.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == partial.count)
        rejected("部分JSON写入必须拒绝") { _ = try LegacyReceipt.read(from: descriptor) }
        for (field, value): (String, Any) in [("version", 2), ("version", true), ("userID", true),
                ("userID", 0), ("userID", UInt64(UInt32.max) + 1), ("userID", "501"),
                ("wholeMediaRegistryID", 0), ("wholeMediaRegistryID", -1), ("wholeMediaRegistryID", "122"),
                ("token", token.lowercased()), ("token", "../旧凭据"), ("status", -1), ("status", 256),
                ("status", 0.5), ("status", false)] {
            var changed = original; changed[field] = value
            try replace(changed)
            rejected("字段类型、范围、版本或UUID不规范拒绝：\(field)") { _ = try LegacyReceipt.read(from: descriptor) }
        }
        var changed = original; changed.removeValue(forKey: "status")
        try replace(changed)
        rejected("缺少必需字段拒绝") { _ = try LegacyReceipt.read(from: descriptor) }
        changed = original; changed["extra"] = 1
        try replace(changed)
        rejected("未知协议字段拒绝") { _ = try LegacyReceipt.read(from: descriptor) }
        changed = original; changed["status"] = 5
        try replace(changed)
        let failed = try LegacyReceipt.read(from: descriptor)!
        rejected("非0最终状态必须拒绝成功判定") { try failed.requireClean(wholeMediaRegistryID: 122) }
        changed = original; changed["wholeMediaRegistryID"] = UInt64.max
        try replace(changed)
        let maximum = try LegacyReceipt.read(from: descriptor)!
        try maximum.requireClean(wholeMediaRegistryID: UInt64.max)
        checks.append("UInt64最大登记ID按整数精确保留，不转Double丢精度")
        let overflow = "{\"version\":1,\"userID\":501,\"wholeMediaRegistryID\":18446744073709551616,\"token\":\"\(token)\",\"status\":0}"
        let data = Data([1]) + Data(overflow.utf8)
        precondition(ftruncate(descriptor, 0) == 0)
        precondition(data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == data.count)
        rejected("超过UInt64的整盘登记ID拒绝") { _ = try LegacyReceipt.read(from: descriptor) }
        precondition(ftruncate(descriptor, 4097) == 0)
        rejected("超4096字节回执在读取前拒绝") { _ = try LegacyReceipt.read(from: descriptor) }
        rejected("无效FD拒绝") { _ = try LegacyReceipt.read(from: -1) }
        func readFixture(_ suffix: String) throws -> LegacyReceipt? {
            let file = open(fixturePrefix + "." + suffix, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw HelperFailure(message: "无法读取指定C writer普通文件产物。") }
            defer { close(file) }
            return try LegacyReceipt.read(from: file)
        }
        let crossLanguageToken = "11111111-2222-4333-8444-555555555555"
        guard let clean = try readFixture("status0") else { fatalError("C成功回执不能是空文件") }
        try clean.requireClean(wholeMediaRegistryID: 9_876_543_210, userID: getuid(), token: crossLanguageToken)
        checks.append("真实C writer状态0产物通过Swift严格读取与完整身份检查")
        rejected("真实C writer进行中产物被Swift拒绝") { _ = try readFixture("pending") }
        guard let error = try readFixture("status74") else { fatalError("C错误回执不能是空文件") }
        precondition(error.status == 74 && error.wholeMediaRegistryID == 9_876_543_210 && error.token == crossLanguageToken)
        rejected("真实C writer状态74产物不能被Swift判定干净") {
            try error.requireClean(wholeMediaRegistryID: 9_876_543_210, userID: getuid(), token: crossLanguageToken)
        }
        rejected("真实C writer同步失败产物被Swift拒绝") { _ = try readFixture("syncfail") }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["结果": "通过", "数量": checks.count,
            "检查": checks, "边界": "仅自建普通文件与构造回执；未验证真实root媒体锁、前端最终关闭或系统磁盘操作。nil不代表卸载或弹盘干净。"],
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
