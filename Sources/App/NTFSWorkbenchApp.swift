import SwiftUI
import AppKit

@main struct NTFSWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("NTFS 畅写 · NTFS WriteFlow", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 840, minHeight: 560)
                .task {
                    await model.refresh()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        if !Task.isCancelled && model.automaticRefresh { await model.refresh() }
                    }
                }
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

final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
