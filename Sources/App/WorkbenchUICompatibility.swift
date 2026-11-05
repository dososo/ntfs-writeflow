import AppKit
import SwiftUI

// 仅桥接13/14缺少的场景启动抑制和设置入口；界面内容及状态仍由SwiftUI持有。
@MainActor enum WorkbenchUICompatibility {
    static weak var legacyWindows: WorkbenchLegacyWindows?

    static func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    static func open(_ id: String, model: AppModel, using action: OpenWindowAction?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if #available(macOS 15.0, *) { action?(id: id) }
        else { legacyWindows?.show(id, model: model) }
        activate()
    }

    static func showLegacySettings(model: AppModel) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        legacyWindows?.show("settings", model: model)
        activate()
    }
}

// 生命周期由应用委托持有；关闭窗口保留同一实例，不登记窗口恢复或自动创建窗口。
@MainActor final class WorkbenchLegacyWindows {
    private var windows: [String: NSWindow] = [:]

    func show(_ id: String, model: AppModel) {
        if let window = windows[id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let content: AnyView
        let size: NSSize
        let minimum: NSSize
        let title: String
        switch id {
        case "main":
            content = AnyView(ContentView(model: model).frame(minWidth: 840, minHeight: 560))
            size = NSSize(width: 1040, height: 680); minimum = NSSize(width: 840, height: 560)
            title = "NTFS 畅写 · NTFS WriteFlow"
        case "diagnostics":
            content = AnyView(DiagnosticsView(model: model).frame(minWidth: 530, minHeight: 400))
            size = NSSize(width: 560, height: 450); minimum = NSSize(width: 530, height: 400)
            title = "诊断"
        case "settings":
            content = AnyView(WorkbenchSettingsView(model: model))
            size = NSSize(width: 560, height: 660); minimum = size
            title = "设置"
        default: return
        }
        let style: NSWindow.StyleMask = id == "settings" ? [.titled, .closable] : [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("writeflow." + id)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = minimum
        window.contentView = NSHostingView(rootView: content)
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}
