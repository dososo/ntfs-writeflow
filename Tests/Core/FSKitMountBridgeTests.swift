import Foundation
import Darwin

@main enum FSKitMountBridgeTests {
    static func main() throws {
        precondition(geteuid() != 0, "只允许运行无提权测试")
        var checks: [String] = []
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks.append(message) }
        func rejected(_ name: String, _ work: () throws -> Void) {
            do { try work(); fatalError(name) }
            catch is HelperFailure { checks.append(name) }
            catch is LegacyRuntime.Failure { checks.append(name) }
            catch { fatalError("非预期错误：\(error)") }
        }
        let token = "ABCDEFAB-2222-4333-8444-555555555555"
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        let request = PrivilegedMountRequest(deviceID: "disk99s1", mediaRegistryID: 123,
            wholeMediaRegistryID: 122, mediaByteCount: 134_217_728, readOnly: true)
        let ticket = HelperTicket(userID: 501, token: token, request: request)
        let arguments = ["--internal-fskit-mount", "501", token, "disk99s1", "123", "122", "134217728", "ro"]
        for (major, minor, expected) in [(13, 0, false), (14, 7, false), (15, 3, false), (15, 4, true),
                                       (15, 7, true), (25, 0, true), (26, 0, false), (27, 2, false)] {
            check(FSKitMountBridge.isRequired(on: .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) == expected,
                  "平台\(major).\(minor)只选择15.4至26之前的兼容身份桥")
        }
        check(try FSKitMountBridge.arguments(for: ticket) == arguments, "父进程只编码固定模式和原凭据字段")
        let parsed = try FSKitMountBridge.parse(arguments, on: version)
        try HelperNamespace.UnmountLease.verifyTicket(parsed, expected: ticket)
        checks.append("严格解析保留UID、规范token和全部原介质请求字段")
        let invocation = try FSKitMountBridge.invocation(for: ticket)
        let cache = PrivilegedMountConfiguration.namespace + "/501/\(token)/runtime/NTFSWriteFlowMountHelper"
        check(invocation.0 == "/bin/launchctl" && invocation.1 == ["asuser", "501", cache] + arguments,
              "会话路由只能启动当前凭据内固定root缓存助手，不启动原app路径")
        let mount = try HelperCommand.systemMountArguments(request, userID: 501, token: token)
        check(mount == ["-F", "-t", "blntfs", "-o", "ro,nosuid,nodev,noowners,nobrowse,writeflow-media-id=123",
                        "/dev/disk99s1", PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"],
              "最终mount设备、选项和目标仅由已核验字段派生")
        for (index, invalid) in [(0, "--other"), (1, "0"), (1, "500"), (1, "4294967295"), (1, "+501"),
                                 (1, "0501"), (2, token.lowercased()), (2, "../volume"), (3, "disk99s1;id"),
                                 (3, "/dev/disk99s1"), (4, "0"), (4, "18446744073709551616"), (4, "0123"),
                                 (5, "0"), (6, "0"), (6, "-1"), (6, "9223372036854775808"), (7, "rw,exec")] {
            var changed = arguments; changed[index] = invalid
            rejected("拒绝字段\(index)无效值\(invalid)") { _ = try FSKitMountBridge.parse(changed, on: version) }
        }
        for changed in [Array(arguments.dropLast()), arguments + ["--extra"]] {
            rejected("缺参数或多参数不能进入内部挂载模式") { _ = try FSKitMountBridge.parse(changed, on: version) }
        }
        for version in [OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)] {
            rejected("不适用系统拒绝内部模式，不能绕过平台选择") { _ = try FSKitMountBridge.parse(arguments, on: version) }
        }
        let rw = Array(arguments.dropLast()) + ["rw"]
        check(try FSKitMountBridge.parse(rw, on: version).request.readOnly == false, "仅固定rw值可选择写入")
        rejected("已有挂载身份的旧凭据不能启动新挂载") {
            _ = try FSKitMountBridge.arguments(for: HelperTicket(userID: 501, token: token, request: request,
                fileSystemIdentity: "旧实例"))
        }
        rejected("普通用户不能准备root助手缓存") {
            _ = try LegacyRuntime.prepareMountHelper(in: -1, userID: 501, token: token)
        }
        rejected("Apple系统程序不能冒充本应用团队及helper标识") {
            try LegacyRuntime.verifyMountHelperSignature(at: "/bin/ls")
        }
        rejected("本测试程序原路径不能冒充当前token的root缓存helper") {
            try LegacyRuntime.verifyCurrentMountHelper(userID: 501, token: token)
        }
        var metadata = stat()
        metadata.st_uid = 0; metadata.st_mode = S_IFREG | 0o500; metadata.st_nlink = 1
        metadata.st_dev = 1; metadata.st_ino = 2
        try LegacyRuntime.verifyMountHelperFile(metadata, entry: metadata)
        checks.append("仅构造元数据：root500单链接普通文件且FD与路径身份一致")
        for kind in 0..<6 {
            var changed = metadata
            switch kind {
            case 0: changed.st_uid = 501
            case 1: changed.st_mode = S_IFREG | 0o600
            case 2: changed.st_mode = S_IFLNK | 0o500
            case 3: changed.st_nlink = 2
            case 4: changed.st_ino += 1
            default: changed.st_dev += 1
            }
            rejected("助手缓存元数据或路径身份异常\(kind)拒绝；仅模拟root元数据") {
                if kind < 4 { try LegacyRuntime.verifyMountHelperFile(changed, entry: changed) }
                else { try LegacyRuntime.verifyMountHelperFile(metadata, entry: changed) }
            }
        }
        rejected("普通用户不能执行内部模式或创建监听") { try FSKitMountBridge.execute(arguments) }
        let before = (getuid(), geteuid())
        let result = "/dev/rdisk99999999".withCString { device in
            "/不存在".withCString { path in
                "ro".withCString { options in writeflow_exec_fskit_mount(501, options, device, path) }
            }
        }
        check(result == EPERM && getuid() == before.0 && geteuid() == before.1,
              "C最终门禁在普通用户下拒绝且不改变凭据、不exec、不接触设备")
        let output = try HelperCommand.runBridge("/bin/sh", ["-c", "printf 正常"], timeout: 2)
        check(String(decoding: output, as: UTF8.self) == "正常", "专用runner明确正常退出才返回有限输出")
        rejected("专用runner明确非零退出不报成功") {
            _ = try HelperCommand.runBridge("/bin/sh", ["-c", "printf 拒绝; exit 74"], timeout: 2)
        }
        for body in ["trap '' TERM; /bin/sleep 0.6", "trap 'exit 0' TERM; /bin/sleep 0.6"] {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                _ = try HelperCommand.runBridge("/bin/sh", ["-c", body], timeout: 0.15)
                fatalError("超时后不能按退出0或TERM请求报成功")
            } catch let error as HelperCommand.Uncertain {
                check(error.processID > 0 && ProcessInfo.processInfo.systemUptime - start < 0.5,
                      "超时有界返回未知状态和PID；不等待忽略TERM或随后退出0的子程序")
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        _ = try HelperCommand.runBridge("/bin/sh", ["-c", "/bin/sleep 0.6 & exit 0"], timeout: 2)
        check(ProcessInfo.processInfo.systemUptime - start < 0.5, "已退出父程序的后代持stdout不会阻塞EOF")
        do {
            _ = try HelperCommand.runBridge("/不存在的程序", [], timeout: 2)
            fatalError("spawn状态未知不能报成功")
        } catch is HelperCommand.Uncertain { checks.append("启动失败保守返回专用未知状态") }
        let bounded = try HelperCommand.runBridge("/bin/sh", ["-c", "printf '%131072s' x"], timeout: 2)
        check(bounded.count == 65_536, "输出读取最多64KiB，不追读后代或无限增长文件")
        check(try HelperNamespace.bridgeNamespaceUserID("501") == 501 &&
              HelperNamespace.bridgeNamespaceUserID("media-leases") == nil, "扫描只识别规范UID目录及固定媒体租约目录")
        for entry in ["0", "500", "0501", "4294967295", "其他目录", "501.lock"] {
            rejected("未知namespace条目\(entry)拒绝扫描") { _ = try HelperNamespace.bridgeNamespaceUserID(entry) }
        }
        check(try HelperNamespace.bridgeTokens(from: [token]) == [token], "扫描接受规范token目录")
        rejected("UID目录下未知项不能被过滤后视为空") { _ = try HelperNamespace.bridgeTokens(from: [token, "未知文件"]) }
        for userID: UInt32 in [501, 502] {
            rejected("同whole跨UID\(userID)既存未确认票据阻断新挂载，不能按当前无VFS放行") {
                try HelperNamespace.requireNoPendingBridgeTicket(HelperTicket(userID: userID, token: token, request: request),
                    wholeMediaRegistryID: 122)
            }
        }
        try HelperNamespace.requireNoPendingBridgeTicket(ticket, wholeMediaRegistryID: 999)
        checks.append("其他whole的未确认票据不阻断本整盘")
        try HelperNamespace.requireNoPendingBridgeTicket(HelperTicket(userID: 502, token: token, request: request,
            fileSystemIdentity: "已核验实例"), wholeMediaRegistryID: 122)
        checks.append("已有实际FSID核验的同whole票据不算未决")
        rejected("空FSID不能冒充已确认票据") {
            try HelperNamespace.requireNoPendingBridgeTicket(HelperTicket(userID: 501, token: token, request: request,
                fileSystemIdentity: ""), wholeMediaRegistryID: 122)
        }
        let ordinary = HelperFailure(message: "明确拒绝")
        check(!FSKitMountBridge.mustPreserveTicket(commandSucceeded: false, error: ordinary), "明确非零拒绝可进入现有无VFS清理")
        check(FSKitMountBridge.mustPreserveTicket(commandSucceeded: false, error: HelperCommand.Uncertain(processID: 1)),
              "超时或执行未知必须保票据与缓存")
        check(FSKitMountBridge.mustPreserveTicket(commandSucceeded: true, error: ordinary),
              "命令退出0后最终VFS或模式核验失败仍必须保票据与缓存")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["结果": "通过", "数量": checks.count,
            "检查": checks, "边界": "真实生产解析和固定路由、签名反例及普通用户拒绝；没有执行root缓存、改变凭据、挂载或访问设备。"],
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
