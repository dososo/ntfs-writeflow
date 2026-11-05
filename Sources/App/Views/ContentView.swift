import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var ejectTarget: VolumeRecord?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("磁盘").font(.largeTitle.bold())
                    Text("\(model.ntfsVolumes.count) 个 NTFS 卷").foregroundStyle(.secondary)
                }.padding(20)
                List(selection: $model.selectedID) {
                    ForEach(model.volumes) { volume in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(volume.name).lineLimit(1)
                                Text(volume.access.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: volume.isInternal == true ? "internaldrive" : "externaldrive")
                        }
                        .tag(volume.id)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Toggle("显示其他文件系统", isOn: $model.showOtherVolumes)
                    .toggleStyle(.checkbox).padding(16)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 255, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    message(error, symbol: "exclamationmark.triangle", color: .orange)
                } else if let text = model.operationMessage {
                    message(text, symbol: "checkmark.circle", color: .green)
                }
                if model.unreadableCount > 0 {
                    message("\(model.unreadableCount) 个设备状态暂时无法读取。", symbol: "info.circle", color: .secondary)
                }
                if let volume = model.selectedVolume {
                    VolumeDetailView(volume: volume, busy: model.isBusy, current: model.inventoryIsCurrent,
                        open: { Task { await model.openInFinder(volume) } },
                        eject: { ejectTarget = volume },
                        mount: { readOnly in Task { await model.mount(volume, readOnly: readOnly) } },
                        unmount: { Task { await model.unmount(volume) } },
                        autoMode: model.autoMode(for: volume),
                        canRememberAutoWrite: model.canRememberAutoWrite(volume),
                        autoStatus: model.autoStatus,
                        setAutoMode: { model.setAutoMode($0, volume: volume) })
                } else {
                    ContentUnavailableView {
                        Label(model.showOtherVolumes ? "尚未发现可显示的卷" : "尚未发现 NTFS 磁盘", systemImage: "externaldrive.badge.questionmark")
                    } description: {
                        Text(model.showOtherVolumes ? "连接磁盘后刷新，查看系统报告的卷状态。" : "连接 NTFS 格式的磁盘，或打开左下角选项查看其他文件系统。")
                    } actions: {
                        Button("刷新磁盘") { Task { await model.refresh() } }.disabled(model.isBusy)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                    Text("开发验证版 · 系统镜像读写已验证，完整发布验收进行中")
                    Spacer()
                    Button("查看诊断") { openWindow(id: "diagnostics") }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 10) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    if let date = model.lastRefresh {
                        Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(model.isBusy)
                }
            }
        }
        .confirmationDialog("弹出整块磁盘？", isPresented: Binding(
            get: { ejectTarget != nil }, set: { if !$0 { ejectTarget = nil } }), presenting: ejectTarget) { target in
                Button("弹出整盘") { Task { await model.eject(target) } }
                Button("取消", role: .cancel) {}
            } message: { target in
                Text("将弹出“\(target.name)”所在的整块磁盘及其所有分卷。请先保存正在编辑的文件。")
            }
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout).padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
    }
}
