import AppKit
import Foundation

// 直接使用原字节生产窗口控制器；模型和视图来自无磁盘替身，不强制伪造生产系统版本。
@main enum LegacyWindowControllerHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LegacyWindowHostDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class LegacyWindowHostDelegate: NSObject, NSApplicationDelegate {
    private let windows = WorkbenchLegacyWindows()
    private var model: AppModel!

    func applicationWillFinishLaunching(_ notification: Notification) {
        model = AppModel()
        WindowLifecycleProbe.shared.legacyWindows = windows
        model.startAutomaticSessionMonitoring()
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "独立窗口验收", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出独立验收", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        for (title, action) in [("主窗口", #selector(showMain)), ("诊断", #selector(showDiagnostics)), ("设置", #selector(showSettings))] {
            let item = windowMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let login = LoginLaunchService.wasLaunchedAtLogin
        Task { await model.startMonitoring(launchedAtLogin: login) }
        if login { NSApp.setActivationPolicy(.accessory) }
        else { showMain() }
    }

    private func show(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        windows.show(id, model: model)
        WorkbenchUICompatibility.activate()
    }
    @objc private func showMain() { show("main"); model.requestAutomaticForegroundConfirmation() }
    @objc private func showDiagnostics() { show("diagnostics") }
    @objc private func showSettings() { show("settings") }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stopMonitoring() }
}
