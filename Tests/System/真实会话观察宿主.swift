import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

// 测试默认值不落盘，也不读取生产自动挂载策略。
private final class HostDefaults: UserDefaults, @unchecked Sendable {
    override func bool(forKey defaultName: String) -> Bool { false }
    override func data(forKey defaultName: String) -> Data? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@MainActor @Observable
private final class HostDiskAudit {
    var recordAttempts = 0
    var mountAttempts = 0
}

@MainActor @Observable
private final class SessionHost {
    let model: AppModel
    let audit: HostDiskAudit
    var outputPath = "尚未开始"
    var remainingSeconds = 600
    var latestSummary = "等待启动"
    var recentEvents: [String] = []
    var errorMessage: String?
    @ObservationIgnored private var writer: FileHandle?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var started = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var lastState: Data?
    @ObservationIgnored private var finished = false

    init() {
        let audit = HostDiskAudit()
        self.audit = audit
        let runtime = AutoMountRuntime(record: { _ in
            audit.recordAttempts += 1
            throw DiskOperationError(message: "观察宿主拒绝全部磁盘读取请求")
        }, mount: { _, _ in
            audit.mountAttempts += 1
            throw DiskOperationError(message: "观察宿主拒绝全部磁盘挂载请求")
        }, environment: {
            AutoMountEnvironment(isClear: false, reason: "隔离会话观察不运行磁盘策略")
        }, sessionAllowed: { false }, loginState: { .notRegistered })
        model = AppModel(defaults: HostDefaults(suiteName: "com.blteam.writeflow.session-observer")!,
                         autoMountRuntime: runtime)
    }

    func start() throws {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("真实会话观察-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("真实信号与生产状态.jsonl")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw DiskOperationError(message: "无法创建本轮观察日志")
        }
        writer = try FileHandle(forWritingTo: file)
        outputPath = file.path
        started = ProcessInfo.processInfo.systemUptime
        deadline = ContinuousClock.now.advanced(by: .seconds(600))
        model.startAutomaticSessionMonitoring()
        installTraceObservers()
        record("观察启动；没有初始确认请求")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func installTraceObservers() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let signals: [(NotificationCenter, Notification.Name, String)] = [
            (app, NSApplication.didBecomeActiveNotification, "应用激活"),
            (app, .NSApplicationProtectedDataWillBecomeUnavailable, "DP即将不可用"),
            (app, .NSApplicationProtectedDataDidBecomeAvailable, "DP已可用"),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "工作区会话失活"),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, "工作区会话活动"),
            (workspace, NSWorkspace.willSleepNotification, "系统将睡眠"),
            (workspace, NSWorkspace.didWakeNotification, "系统已唤醒"),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "非公开锁屏辅助信号"),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "非公开解锁辅助信号")
        ]
        for (center, name, label) in signals {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record("真实信号到达：\(label)")
                    // 第二条是处理后观察，不声称通知中心对观察者提供固定顺序。
                    Task { @MainActor [weak self] in self?.record("信号后主执行器采样：\(label)") }
                }
            }
            observers.append((center, token))
        }
    }

    func confirm() {
        record("用户点击确认前")
        model.requestAutomaticForegroundConfirmation()
        record("用户点击确认后")
    }

    private func tick() {
        if let deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            remainingSeconds = max(0, Int(remaining.seconds))
            if ContinuousClock.now >= deadline {
                finish("达到十分钟观察上限")
                NSApp.terminate(nil)
                return
            }
        }
        if model.autoEnabled || model.diskMonitor != nil || audit.recordAttempts != 0 || audit.mountAttempts != 0 {
            record("安全护栏发现异常，立即停止")
            finish("观察边界异常")
            NSApp.terminate(nil)
            return
        }
        record("状态变化采样", changedOnly: true)
    }

    private func snapshot() -> [String: Any] {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let uid = (session?[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value
        return [
            "前台确认": model.autoSession.foregroundConfirmed,
            "模型DP可用": model.autoSession.protectedDataAvailable,
            "DP闭锁": model.autoSession.protectedDataBlocked,
            "睡眠闭锁": model.autoSession.sleeping,
            "工作区活动": model.autoSession.workspaceActive,
            "撤销代数": model.autoSessionRevocationEpoch,
            "存在待确认请求": model.autoForegroundRequest != nil,
            "系统应用活动": NSApp.isActive,
            "系统DP可用": NSApp.isProtectedDataAvailable,
            "控制台字典可用": session != nil,
            "控制台UID": uid.map { $0 as Any } ?? NSNull(),
            "进程有效UID": geteuid(),
            "会话在控制台": (session?[kCGSessionOnConsoleKey as String] as? Bool).map { $0 as Any } ?? NSNull(),
            "登录已完成": (session?[kCGSessionLoginDoneKey as String] as? Bool).map { $0 as Any } ?? NSNull(),
            "自动管理开关": model.autoEnabled,
            "磁盘事件监控存在": model.diskMonitor != nil,
            "磁盘读取尝试": audit.recordAttempts,
            "磁盘挂载尝试": audit.mountAttempts,
            "范围": "隔离宿主链接生产模型；不是正式安装应用、真实登录或实体盘验收"
        ]
    }

    func record(_ event: String, changedOnly: Bool = false) {
        guard !finished else { return }
        do {
            var state = snapshot()
            let comparable = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
            if changedOnly && comparable == lastState { return }
            lastState = comparable
            sequence += 1
            state["到达顺序"] = sequence
            state["到达秒数"] = ProcessInfo.processInfo.systemUptime - started
            state["日期"] = ISO8601DateFormatter().string(from: Date())
            state["事件"] = event
            var data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
            data.append(0x0a)
            try writer?.write(contentsOf: data)
            try writer?.synchronize()
            latestSummary = "前台确认：\(model.autoSession.foregroundConfirmed)  ｜ DP闭锁：\(model.autoSession.protectedDataBlocked)\n睡眠闭锁：\(model.autoSession.sleeping)  ｜ 工作区活动：\(model.autoSession.workspaceActive)\n撤销代数：\(model.autoSessionRevocationEpoch)  ｜ 待确认请求：\(model.autoForegroundRequest != nil)"
            recentEvents.append("\(sequence). \(event)")
            if recentEvents.count > 12 { recentEvents.removeFirst() }
        } catch { errorMessage = "日志写入失败：\(error.localizedDescription)" }
    }

    func finish(_ reason: String) {
        guard !finished else { return }
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        model.stopMonitoring()
        record(reason)
        finished = true
        try? writer?.close(); writer = nil
    }
}

private struct SessionHostView: View {
    let host: SessionHost
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("真实会话安全观察").font(.title.bold())
            Text("自动管理始终关闭；不会操作磁盘。仅由你手动锁屏、解锁或切换用户。")
                .foregroundStyle(.secondary)
            Text(host.latestSummary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(host.model.automaticSessionStatus)
            HStack {
                Button("确认当前会话") { host.confirm() }.buttonStyle(.borderedProminent)
                Button("结束观察") { host.finish("用户结束观察"); NSApp.terminate(nil) }
                Spacer()
                Text("剩余约 \(host.remainingSeconds) 秒")
            }
            Divider()
            Text("先点击确认，再手动锁屏并解锁；解锁后应保持未确认，再手动点击确认。")
            Text("只有锁屏解锁不一定触发睡眠或用户切换，没收到的信号仍待测。")
                .font(.callout).foregroundStyle(.secondary)
            Text(host.recentEvents.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let error = host.errorMessage { Text(error).foregroundStyle(.red) }
            Text("日志：\(host.outputPath)").font(.caption).textSelection(.enabled)
            Text("隔离宿主使用生产模型；不等于正式安装应用、真实登录或实体盘验收。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 780, minHeight: 620)
    }
}

@MainActor private final class SessionHostDelegate: NSObject, NSApplicationDelegate {
    var host: SessionHost?
    func applicationWillFinishLaunching(_ notification: Notification) {
        do { try host?.start() }
        catch {
            FileHandle.standardError.write(Data("观察宿主启动失败：\(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { host?.finish("观察宿主关闭") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct SessionObservationApplication: App {
    @NSApplicationDelegateAdaptor(SessionHostDelegate.self) private var delegate
    @State private var host: SessionHost
    init() {
        let host = SessionHost()
        _host = State(initialValue: host)
        delegate.host = host
    }
    var body: some Scene {
        Window("NTFS 畅写 · 会话安全观察宿主", id: "session-observer") {
            SessionHostView(host: host)
        }
        .restorationBehavior(.disabled)
    }
}
