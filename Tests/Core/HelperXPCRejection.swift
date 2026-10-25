import Foundation
import Security
import Darwin

// 错误签名客户端只发送 mountedVolumes；不注册、不挂载、不卸载。
// 编译后默认不连接，必须显式传入 --connect-read-only。
// 验收顺序：正式应用同 UID 合法业务调用成功 → 本探针 → 正式应用同 UID 再次调用成功。
// 正向对照可为挂载、正常卸载或受管挂载查询；不需要为验收新增产品接口。
// 三次请求须使用同一已启用的助手版本；同时保存该时间段的助手/系统 XPC 日志。
// 日志须明确匹配本探针 PID/签名身份的客户端要求失败，不能只有服务失联或 4099。
// 4099 同时可能表示服务不存在或签名拒绝；4102 在本客户端代表助手签名不符，
// 也不能证明助手拒绝了本探针。探针只输出观察，永远不单独判定“拒绝通过”。
// 收到应用层回复即说明请求已进入接口，按安全验收失败处理（退出 1）；
// 连接错误/中断/超时均退出 2，必须结合上述双向对照与拒绝日志人工判定。

private final class ProbeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private let runID = UUID().uuidString
    private let signatureStatus: OSStatus
    private var events: [[String: Any]] = []
    private var finished = false

    init(signatureStatus: OSStatus) { self.signatureStatus = signatureStatus }

    func record(_ name: String, error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        var event: [String: Any] = ["事件": name, "时间": Self.time(Date())]
        if let error {
            let value = error as NSError
            event["错误域"] = value.domain
            event["错误码"] = value.code
            event["错误说明"] = value.localizedDescription
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                event["底层错误域"] = underlying.domain
                event["底层错误码"] = underlying.code
                event["底层错误说明"] = underlying.localizedDescription
            }
        }
        events.append(event)
    }

    func finish(serviceReplied: Bool = false) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let output: [String: Any] = [
            "探针": "错误签名客户端的受管挂载只读查询",
            "运行标识": runID,
            "进程编号": getpid(), "用户编号": geteuid(),
            "开始时间": Self.time(started), "结束时间": Self.time(Date()),
            "服务": PrivilegedMountConfiguration.machServiceName,
            "接口": "mountedVolumes",
            "客户端签名要求检查状态": signatureStatus,
            "观察": serviceReplied ? "收到应用层回复：错误签名客户端进入接口" : "未收到应用层回复：原因待核实",
            "自动结论": serviceReplied ? "失败" : "未判定",
            "后续证据": "必须有同 UID 正式应用前后成功的合法业务调用（如挂载、正常卸载或受管挂载查询），以及关联本 PID 的系统客户端签名拒绝日志；服务不存在、4099、4102 或超时均不能单独判定拒绝通过。",
            "事件": events
        ]
        lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        exit(serviceReplied ? 1 : 2)
    }

    private static func time(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }
}

@main enum HelperXPCRejection {
    static func main() { runProbe() }

    // NSXPC 在自身队列回调；不能继承 Swift 6 入口的 MainActor 隔离。
    nonisolated private static func runProbe() {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--connect-read-only"] else {
            print("仅编译待验收探针。执行只读连接需显式参数 --connect-read-only；本次未连接服务。")
            exit(64)
        }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(PrivilegedMountConfiguration.clientRequirement as CFString,
                                             [], &requirement) == errSecSuccess, let requirement else {
            print("无法核验探针签名，未连接服务。")
            exit(64)
        }
        let status = SecCodeCheckValidity(code, [], requirement)
        guard status != errSecSuccess else {
            print("本探针意外满足正式客户端签名要求，不能作为错误签名测试，未连接服务。")
            exit(64)
        }
        let observation = ProbeObservation(signatureStatus: status)
        let connection = NSXPCConnection(machServiceName: PrivilegedMountConfiguration.machServiceName,
                                         options: .privileged)
        connection.setCodeSigningRequirement(PrivilegedMountConfiguration.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedMountProtocol.self)
        connection.invalidationHandler = { observation.record("连接失效，不能据此区分服务不存在与拒绝") }
        connection.interruptionHandler = { observation.record("连接中断，不能据此判定签名拒绝") }
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            observation.record("代理调用错误", error: error)
            // 留出短暂时间记录随后抵达的失效事件；不据错误码直接宣布通过。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { observation.finish() }
        }
        guard let service = proxy as? PrivilegedMountProtocol else {
            observation.record("无法建立接口代理")
            observation.finish()
            return
        }
        observation.record("提交只读 mountedVolumes 请求")
        service.mountedVolumes { data, error in
            // 不输出挂载路径、卷名等用户数据；任何应用层回复均证明接口被调用。
            observation.record(error == nil ? "收到数据回复（\(data?.count ?? 0) 字节）" : "收到应用层错误回复")
            observation.finish(serviceReplied: true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            observation.record("等待期限已到，不能据此判定签名拒绝")
            observation.finish()
        }
        withExtendedLifetime(connection) { dispatchMain() }
    }
}
