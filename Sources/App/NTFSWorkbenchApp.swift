import SwiftUI
import AppKit

@main struct NTFSWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let initial = AppModel()
        _model = StateObject(wrappedValue: initial)
        delegate.model = initial
    }
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        let _ = delegate.windowOpener = openWindow
        let _ = delegate.model = model
        let _ = WorkbenchUICompatibility.legacyWindows = delegate.legacyWindows
        if #available(macOS 15.0, *) {
            Window("NTFS 畅写 · NTFS WriteFlow", id: "main") {
                ContentView(model: model)
                    .frame(minWidth: 840, minHeight: 560)
            }
            .defaultSize(width: 1040, height: 680)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("刷新磁盘") { Task { await model.refresh() } }
                        .keyboardShortcut("r")
                        .disabled(model.isBusy)
                }
            }

            Window("诊断", id: "diagnostics") {
                DiagnosticsView(model: model).frame(minWidth: 530, minHeight: 400)
            }
            .defaultSize(width: 560, height: 450)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)

            Settings { WorkbenchSettingsView(model: model) }
                .restorationBehavior(.disabled)
        }

        MenuBarExtra("NTFS 畅写", systemImage: "externaldrive", isInserted: $showMenuBar) {
            WorkbenchMenu(model: model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                if #unavailable(macOS 15.0) {
                    Button("刷新磁盘") { Task { await model.refresh() } }
                        .keyboardShortcut("r")
                        .disabled(model.isBusy)
                }
            }
            CommandGroup(after: .appSettings) {
                if #unavailable(macOS 15.0) {
                    Button("设置…") { WorkbenchUICompatibility.showLegacySettings(model: model) }
                        .keyboardShortcut(",")
                }
            }
        }
    }
}

@MainActor final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var windowOpener: OpenWindowAction?
    let legacyWindows = WorkbenchLegacyWindows()

    override init() {
        super.init()
        WorkbenchUICompatibility.legacyWindows = legacyWindows
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        model?.startAutomaticSessionMonitoring()
        model?.recordSessionVerification("即将完成启动")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = LoginLaunchService.wasLaunchedAtLogin
        Task {
            await model?.startMonitoring(launchedAtLogin:loginLaunch)
            model?.recordSessionVerification("磁盘监控启动完成")
        }
        if loginLaunch {
            NSApp.setActivationPolicy(.accessory)

        } else {
            presentMainWindow()
        }
        model?.recordSessionVerification("启动完成")
        model?.scheduleSessionVerificationSamples()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow()
        model?.recordSessionVerification("重新打开")
        return false
    }

    private func presentMainWindow() {
        guard let model else { return }
        WorkbenchUICompatibility.open("main", model: model, using: windowOpener)
        model.requestAutomaticForegroundConfirmation()
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopMonitoring()
        model?.recordSessionVerification("正常退出")
    }
}
