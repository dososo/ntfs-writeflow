import SwiftUI

struct VolumeDetailView: View {
    let volume: VolumeRecord
    let busy: Bool
    let current: Bool
    let open: () -> Void
    let eject: () -> Void
    let mount: (Bool) -> Void
    let unmount: () -> Void

    private var stateColor: Color {
        switch volume.access {
        case .readWrite: .green
        case .readOnly: .orange
        case .unmounted, .unknown: .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Image(systemName: volume.isInternal == true ? "internaldrive" : "externaldrive")
                        .font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
                        .frame(width: 76, height: 76)
                        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(volume.name).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
                        Label(volume.access.rawValue, systemImage: volume.access == .readWrite ? "checkmark.circle.fill" : "circle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(stateColor)
                    }
                    Spacer()
                }
                if volume.isNTFS {
                    Label("预览版：重要数据请先备份。Windows 休眠、快速启动或磁盘异常可能影响安全读写；请先在 Windows 中正常关闭并检查磁盘。", systemImage: "exclamationmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(action: open) { Label("在 Finder 中打开", systemImage: "folder") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !current || volume.mountPoint == nil || volume.mediaRegistryID == nil || volume.mountedFileSystem == nil)
                    Button(action: eject) { Label("安全弹出整盘", systemImage: "eject") }
                        .disabled(!AppCapabilities.directEjectEnabled || busy || !current || !volume.canOfferEject)
                }
                if volume.mountPoint == nil && volume.isNTFS {
                    HStack(spacing: 10) {
                        Button("只读挂载") { mount(true) }
                            .disabled(!AppCapabilities.directMountEnabled || busy || !current || !volume.canOfferMount)
                        Button("读写挂载") { mount(false) }
                            .disabled(!AppCapabilities.directMountEnabled || busy || !current || !volume.canOfferMount || volume.writableMedia != true)
                    }
                    if !AppCapabilities.directMountEnabled {
                        Text("挂载入口正在完成介质身份验证，尚未开放。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if volume.isMountedByWriteFlow {
                    Button("卸载此卷", action: unmount)
                        .disabled(busy || !current || !volume.canOfferUnmount)
                } else if volume.isNTFS && volume.mountPoint != nil {
                    Label("此卷由其他驱动或系统挂载。可安全弹出整盘；如需改由 NTFS 畅写挂载，请先通过原工具正常卸载此卷。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !volume.canOfferEject && !volume.isProtectedForEject {
                    Label(volume.isNTFS ? "未确认整盘可弹出或介质身份，请刷新后重试。" : "其他文件系统仅供查看；本应用支持从 NTFS 卷安全弹出其所在整盘。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("容量").font(.headline)
                            Spacer()
                            Text(volume.totalBytes > 0 ? bytes(volume.totalBytes) : "未报告").font(.headline.monospacedDigit())
                        }
                        if volume.mountPoint == nil {
                            Text("挂载后显示可用空间")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let free = volume.freeBytes, volume.totalBytes > 0, free >= 0, free <= volume.totalBytes {
                            ProgressView(value: Double(volume.totalBytes - free), total: Double(volume.totalBytes))
                                .tint(.accentColor)
                            HStack {
                                Text("已用 \(bytes(volume.totalBytes - free))")
                                Spacer()
                                Text("可用 \(bytes(free))")
                            }.font(.caption).foregroundStyle(.secondary)
                            if volume.fileSystem == "apfs" {
                                Text("APFS 卷共享容器可用空间。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("系统未报告可用空间。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
                    row("文件系统", volume.fileSystemName.isEmpty ? "未识别" : volume.fileSystemName)
                    row("实际挂载类型", volume.mountPoint == nil ? "未挂载" : (volume.mountedFileSystem?.type ?? "未核实"))
                    row("挂载位置", volume.mountPoint ?? "未挂载")
                    row("设备", "/dev/\(volume.id)")
                    row("位置", volume.isInternal.map { $0 ? "内部磁盘" : "外部设备或磁盘映像" } ?? "系统未报告")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if volume.isProtected && !volume.isMountedByWriteFlow {
                    Label("此卷仅供查看。本应用不会弹出内部卷或系统路径下的卷。", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                } else if volume.isNTFS {
                    Label(volume.isMountedByWriteFlow ? "当前卷由 NTFS 畅写提供访问。卸载卷与弹出整盘是两个不同操作。" : "此处显示系统当前的访问状态。只有实际挂载类型为 blntfs 才由 NTFS 畅写提供访问。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }
}
