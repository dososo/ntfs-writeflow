import Foundation
import Darwin

@main enum PrivilegedHelperSessionTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        let token = UUID().uuidString
        func request(_ readOnly: Bool, device: String = "disk9999") -> PrivilegedMountRequest {
            PrivilegedMountRequest(deviceID: device, mediaRegistryID: 123, wholeMediaRegistryID: 122,
                mediaByteCount: 134_217_728, readOnly: readOnly)
        }
        for readOnly in [true, false] {
            let invocation = try HelperCommand.mountInvocation(request(readOnly), userID: 501, token: token)
            check(invocation.0 == "/sbin/mount" && Array(invocation.1.prefix(4)) ==
                  ["-F", "-t", "blntfs", "-o"], "只能执行固定挂载程序")
            check(invocation.1[4] == "\(readOnly ? "ro" : "rw"),nosuid,nodev,noowners,nobrowse,writeflow-media-id=123",
                  "挂载选项只能来自固定策略和介质标识")
            check(Array(invocation.1.suffix(2)) == ["/dev/disk9999", PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"],
                  "设备与路径必须规范且由助手派生")
            check(try HelperCommand.environment(for: invocation.0, mountUserID: 501) ==
                  ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "SUDO_UID": "501"],
                  "挂载环境只能携带固定值与可信连接用户标识")
        }
        check(try HelperCommand.environment(for: "/usr/sbin/diskutil") ==
              ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"], "磁盘查询不接收挂载身份或父进程环境")
        for (program, userID): (String, UInt32) in [("/usr/sbin/diskutil", 501), ("/sbin/mount", 0)] {
            do {
                _ = try HelperCommand.environment(for: program, mountUserID: userID)
                fatalError("其他程序或无效用户不得接收挂载身份")
            } catch let error as HelperFailure {
                check(error.message == "仅固定挂载程序可接收可信用户身份。", "环境策略必须在启动前拒绝")
            }
        }
        for (userID, candidate, device): (UInt32, String, String) in [
            (0, token, "disk9999"), (.max, token, "disk9999"), (501, "../other", "disk9999"), (501, token, "disk9999;id")
        ] {
            do {
                _ = try HelperCommand.mountInvocation(request(true, device: device), userID: userID, token: candidate)
                fatalError("无效调用不得执行")
            } catch let error as HelperFailure { check(error.message == "挂载调用参数无效。", "必须在启动进程之前拒绝") }
        }

        let fixture = FileManager.default.currentDirectoryPath + "/build/helper-candidate/恢复验证-\(token)"
        let orphan = fixture + "/volume"
        precondition(mkdir(fixture, 0o700) == 0)
        precondition(mkdir(orphan, 0o700) == 0)
        defer {
            precondition(rmdir(orphan) == 0)
            precondition(rmdir(fixture) == 0)
        }
        let skipped = try PrivilegedMountEngine.loadTicketIfMounted(at: orphan) {
            fatalError("无实际挂载的孤目录不得尝试读取不存在的凭据")
        }
        check(skipped == nil, "未挂载孤目录必须跳过且保持原状")
        // 根目录仅作现成挂载点的 statfs 读取，不执行任何挂载或设备访问。
        do {
            _ = try PrivilegedMountEngine.loadTicketIfMounted(at: "/") {
                throw HelperFailure(message: "模拟缺失凭据")
            }
            fatalError("实际挂载存在时不能吞掉凭据读取失败")
        } catch let error as HelperFailure { check(error.message == "模拟缺失凭据", "实际挂载必须严格读取凭据") }
        let loaded = try PrivilegedMountEngine.loadTicketIfMounted(at: "/") {
            HelperTicket(userID: 501, token: token, request: request(true), fileSystemIdentity: "测试实例")
        }
        check(loaded?.token == token, "实际挂载存在时继续凭据核验流程")
        let report: [String: Any] = ["结果": "通过", "数量": count,
            "范围": "固定mount调用及SUDO_UID环境、无挂载孤目录跳过、已挂载凭据错误不吞掉；未运行挂载命令、未注册服务、未操作设备。"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/build/helper-candidate/会话与恢复验证结果.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
