import SwiftUI
import AppKit

@main struct NTFSWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let initial = AppModel()
        _model = State(initialValue: initial)
        delegate.model = initial
    }
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("NTFS 畅写 · NTFS WriteFlow", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 840, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
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

        Settings { WorkbenchSettingsView(model: model) }

        MenuBarExtra("NTFS 畅写", systemImage: "externaldrive", isInserted: $showMenuBar) {
            WorkbenchMenu(model: model)
        }
    }
}

@MainActor final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = LoginLaunchService.wasLaunchedAtLogin
        Task { await model?.startMonitoring(launchedAtLogin: loginLaunch) }
        if loginLaunch {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows { window.orderOut(nil) }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model?.stopMonitoring() }
}
