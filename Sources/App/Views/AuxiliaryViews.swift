import SwiftUI

struct DiagnosticsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("扩展状态") {
                LabeledContent("系统报告", value: model.extensionDiagnostic.title)
                Text(model.extensionDiagnostic.detail).foregroundStyle(.secondary)
            }
            Section("当前验证范围") {
                Label("磁盘列表来自本机系统", systemImage: "externaldrive")
                Label("系统托管测试镜像的读写闭环已通过", systemImage: "checkmark.circle")
                Text("支持正常卸载与安全弹出整盘，遇到占用时停止。Windows 与异常断电等场景分别验收；格式化和完整修复尚未提供。")
                    .foregroundStyle(.secondary)
            }
            Section("本地诊断") {
                Text("仅导出系统版本、扩展状态和统计数量，不包含卷名、路径、卷标识、账户或用户文件。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("重新查询") { Task { await model.refresh() } }.disabled(model.isBusy)
                    Button("导出诊断…") { model.exportDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

struct WorkbenchSettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        Form {
            Section("显示") {
                Toggle("在菜单栏显示", isOn: $showMenuBar)
                Toggle("显示其他文件系统", isOn: $model.showOtherVolumes)
            }
            Section("刷新") {
                Toggle("自动刷新磁盘状态", isOn: $model.automaticRefresh)
                Text("主窗口打开时，每 20 秒读取一次系统卷状态。关闭后仍可手动刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("物理磁盘挂载") {
                LabeledContent("管理员服务", value: model.mountHelperStatus)
                Text("用于挂载物理 NTFS 磁盘、正常卸载与安全弹出整盘。遇到占用会停止，不强制卸载、不格式化或修复。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.mountHelperEnabled {
                        Button("移除挂载服务") { Task { await model.unregisterMountHelper() } }
                    } else if model.mountHelperNeedsApproval {
                        Button("打开系统授权设置") { model.openMountHelperApproval() }
                    } else {
                        Button("配置管理员挂载服务…") { model.registerMountHelper() }
                    }
                    Button("刷新状态") { model.refreshMountHelperStatus() }
                }.disabled(model.isBusy)
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
        .onAppear { model.refreshMountHelperStatus() }
    }
}

struct WorkbenchMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.ntfsVolumes.count) 个 NTFS 卷")
        ForEach(Array(model.ntfsVolumes.prefix(8))) { volume in
            Menu("\(String(volume.name.prefix(18))) · \(volume.access.rawValue)") {
                Button("在 Finder 中打开") { Task { await model.openInFinder(volume) } }
                    .disabled(volume.mountPoint == nil)
                if volume.canOfferMount {
                    Button("只读挂载") { Task { await model.mount(volume, readOnly: true) } }
                        .disabled(!AppCapabilities.directMountEnabled)
                    Button("读写挂载") { Task { await model.mount(volume, readOnly: false) } }
                        .disabled(!AppCapabilities.directMountEnabled || volume.writableMedia != true)
                }
                if volume.canOfferUnmount {
                    Button("卸载此卷") { Task { await model.unmount(volume) } }
                }
            }.disabled(model.isBusy || !model.inventoryIsCurrent)
        }
        Divider()
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("刷新磁盘") { Task { await model.refresh() } }.disabled(model.isBusy)
        Button("诊断") { openWindow(id: "diagnostics") }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 NTFS 畅写") { NSApp.terminate(nil) }
    }
}
