import Foundation

// 只观察生产监控回调，不注入规则、GUID或竞争结论，不执行挂载。
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    func append(_ stage: String, _ disk: DiskEventSnapshot, _ cached: Bool) {
        lock.lock(); defer { lock.unlock() }
        entries.append(["阶段": stage, "BSD": disk.bsdName, "介质ID": disk.mediaID.map(String.init) ?? "",
                        "卷UUID": disk.volumeUUID ?? "", "文件系统": disk.volumeKind ?? "", "内容类型": disk.contentHint ?? "", "挂载点": disk.mountPath ?? "", "UUID存在": disk.volumeUUID != nil, "容量": disk.mediaSize,
                        "硬件标识存在": disk.deviceGUID != nil, "同代缓存命中": cached])
    }
    func data() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }
}
@main enum NativeSequence {
    static func main() throws {
        guard CommandLine.arguments.count == 1 else { exit(2) }
        let trace = Trace()
        let monitor = DiskEventMonitor(onEvent: { _ in }, onTrace: { trace.append($0, $1, $2) })
        guard monitor.start() else { exit(3) }
        Thread.sleep(forTimeInterval: 1)
        print("监控就绪"); fflush(stdout)
        guard readLine() == "结束" else { monitor.stop(); exit(4) }
        monitor.stop()
        print(String(decoding: try trace.data(), as: UTF8.self))
    }
}
