import SwiftUI
import AppKit
import Foundation

// 只替换依赖；@main App、Window场景与WorkbenchDelegate来自原字节生产文件。
@MainActor final class AppModel {
    let isBusy = false
    init() { WindowLifecycleProbe.configure() }
    func startAutomaticSessionMonitoring() { WindowLifecycleProbe.shared.record("early-session-monitor") }
    func startMonitoring(launchedAtLogin: Bool) async {
        WindowLifecycleProbe.shared.record("start-monitoring", ["login_reason_injected": launchedAtLogin])
    }
    func stopMonitoring() { WindowLifecycleProbe.shared.record("stop-monitoring") }
    func requestAutomaticForegroundConfirmation() { WindowLifecycleProbe.shared.record("request-foreground-confirmation") }
    // 本工具只测生产委托/窗口；限时OSLog记录由真正模型的独立用例验证。
    func recordSessionVerification(_ event: String) {}
    func scheduleSessionVerificationSamples() {}
    func refresh() async { WindowLifecycleProbe.shared.record("fake-refresh") }
}

@MainActor enum LoginLaunchService {
    static var wasLaunchedAtLogin: Bool { WindowLifecycleProbe.shared.loginReason }
}

@MainActor private final class WeakWindow {
    weak var value: NSWindow?
    init(_ window: NSWindow) { value = window }
}

@MainActor final class WindowLifecycleProbe {
    static var shared: WindowLifecycleProbe!
    let root: URL
    let token: String
    let loginReason: Bool
    let output: FileHandle
    let started = Date()
    private var timer: Timer?
    private var commandID: String?
    private var observedSignature: Data?
    private var observers: [NSObjectProtocol] = []
    private var windows: [String: WeakWindow] = [:]
    var openDiagnostics: (() -> Void)?
    var openSettings: (() -> Void)?

    static func configure() {
        guard shared == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WRITEFLOW_WINDOW_PROBE_ROOT"],
              let token = environment["WRITEFLOW_WINDOW_PROBE_TOKEN"], UUID(uuidString: token) != nil,
              let login = environment["WRITEFLOW_WINDOW_PROBE_LOGIN"], ["true", "false"].contains(login),
              let menu = environment["WRITEFLOW_WINDOW_PROBE_MENU"], ["true", "false"].contains(menu) else {
            fatalError("仅允许本次独立测试上下文")
        }
        do {
            shared = try WindowLifecycleProbe(root: URL(fileURLWithPath: path), token: token, login: login == "true")
            UserDefaults.standard.set(menu == "true", forKey: "showMenuBar")
            UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
            shared.record("configured", ["menu_preference": menu == "true", "login_reason_is_injected": true,
                                         "bundle_path": Bundle.main.bundleURL.path,
                                         "bundle_id": Bundle.main.bundleIdentifier ?? ""])
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { shared.poll() }
            }
            shared.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { shared.record("window-notification", ["windows": shared.windowState()]) }
                }
                shared.observers.append(observer)
            }
        } catch { fatalError("无法创建本次测试回执：\(error)") }
    }

    private init(root: URL, token: String, login: Bool) throws {
        self.root = root; self.token = token; loginReason = login
        let path = root.appendingPathComponent("回执.jsonl").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: "窗口验收", code: 1) }
        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event; value["pid"] = Int(getpid()); value["token"] = token
        value["elapsed"] = Date().timeIntervalSince(started)
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? output.write(contentsOf: data + Data([10])); try? output.synchronize()
    }
    func mark(_ role: String, window: NSWindow) { windows[role] = WeakWindow(window) }
    private func windowState() -> [[String: Any]] {
        NSApp.windows.map { window in
            ["number": window.windowNumber, "title": window.title, "class": String(describing: type(of: window)),
             "role": windows.first(where: { $0.value.value === window })?.key as Any? ?? NSNull(),
             "visible": window.isVisible, "miniaturized": window.isMiniaturized,
             "titled": window.styleMask.contains(.titled)]
        }
    }
    func sample(_ id: String) {
        let state = windowState()
        record("sample", ["command_id": id, "windows": state, "active": NSApp.isActive,
                          "activation_policy": NSApp.activationPolicy().rawValue,
                          "menu_preference": UserDefaults.standard.bool(forKey: "showMenuBar")])
    }
    private func poll() {
        let state = windowState()
        if let signature = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), signature != observedSignature {
            observedSignature = signature; record("window-transition", ["windows": state])
        }
        if Date().timeIntervalSince(started) > 60 {
            record("watchdog-expired"); timer?.invalidate(); NSApp.terminate(nil); return
        }
        let path = root.appendingPathComponent("指令.json")
        guard let data = try? Data(contentsOf: path),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = command["id"], id != commandID, command["token"] == token,
              let action = command["action"] else { return }
        commandID = id
        switch action {
        case "sample": sample(id)
        case "diagnostics": openDiagnostics?(); record("action", ["command_id": id, "action": action])
        case "settings": openSettings?(); record("action", ["command_id": id, "action": action])
        case "minimize-main": windows["main"]?.value?.miniaturize(nil); record("action", ["command_id": id, "action": action])
        case "close-main": windows["main"]?.value?.performClose(nil); record("action", ["command_id": id, "action": action])
        case "close-auxiliary":
            windows["diagnostics"]?.value?.performClose(nil); windows["settings"]?.value?.performClose(nil)
            record("action", ["command_id": id, "action": action])
        case "close-all":
            for window in NSApp.windows where window.styleMask.contains(.titled) { window.performClose(nil) }
            record("action", ["command_id": id, "action": action])
        case "quit": record("quit-request", ["command_id": id]); timer?.invalidate(); NSApp.terminate(nil)
        default: record("invalid-command", ["command_id": id])
        }
    }
}

private struct RoleMarker: NSViewRepresentable {
    let role: String
    final class Marker: NSView {
        let role: String
        init(role: String) { self.role = role; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("不支持归档创建") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowLifecycleProbe.shared.mark(role, window: window) }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker(role: role) }
    func updateNSView(_ nsView: Marker, context: Context) {}
}

struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("独立窗口生命周期验收：没有磁盘服务")
            .background(RoleMarker(role: "main"))
            .onAppear {
                WindowLifecycleProbe.shared.openDiagnostics = { openWindow(id: "diagnostics") }
                WindowLifecycleProbe.shared.openSettings = { openSettings() }
            }
    }
}
struct DiagnosticsView: View {
    let model: AppModel
    var body: some View { Text("独立诊断窗口").background(RoleMarker(role: "diagnostics")) }
}
struct WorkbenchSettingsView: View {
    let model: AppModel
    var body: some View { Text("独立设置窗口").frame(width: 400, height: 250).background(RoleMarker(role: "settings")) }
}
struct WorkbenchMenu: View {
    let model: AppModel
    var body: some View { Text("独立验收菜单，无磁盘操作") }
}
