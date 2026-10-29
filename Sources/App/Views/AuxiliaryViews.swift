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
                Label("预览版：验证结果仅适用于报告中的版本与设备", systemImage: "info.circle")
                Text("当前使用 FSKit 与 NTFS-3G，支持 Apple Silicon、macOS 26 及以上。Windows 独立读写、异常断电、Intel 和旧系统尚未完成验收；重要数据请先备份。格式化和完整修复尚未提供。")
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
            Section("插盘自动挂载") {
                Toggle("自动管理已选定的 NTFS 盘", isOn: $model.autoEnabled)
                Text("首次在磁盘详情选择自动只读或读写；之后新插入时自动处理。登录或解锁后先打开一次应用确认会话；之后关闭窗口继续工作，退出应用后停止。遇到其他驱动或身份不明会暂停。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.autoStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                LabeledContent("登录项状态", value: model.loginStatus)
            }
            Section("刷新") {
                Toggle("自动刷新磁盘状态", isOn: $model.automaticRefresh)
                Text("磁盘插入、移除或状态变化后更新列表；不在无盘闲置时定时枚举。关闭后仍可手动刷新。")
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
        .frame(width: 560, height: 660)
        .onAppear { model.refreshMountHelperStatus(); model.refreshLoginStatus() }
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
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("刷新磁盘") { Task { await model.refresh() } }.disabled(model.isBusy)
        Button("诊断") {
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            openWindow(id: "diagnostics")
            NSApp.activate()
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 NTFS 畅写") { NSApp.terminate(nil) }
    }
}
