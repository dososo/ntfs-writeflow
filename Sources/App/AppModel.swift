import AppKit
import Observation
import ServiceManagement

@MainActor @Observable final class AppModel {
    var records: [VolumeRecord] = []
    var selectedID: String? {
        didSet { if oldValue != selectedID { operationMessage = nil } }
    }
    var isRefreshing = false
    var isOperating = false
    var inventoryIsCurrent = false
    var lastRefresh: Date?
    var unreadableCount = 0
    var errorMessage: String?
    var operationMessage: String?
    var extensionDiagnostic = ExtensionDiagnostic.pending
    var mountHelperStatus = "尚未查询"
    var mountHelperNeedsApproval = false
    var mountHelperEnabled = false
    var showOtherVolumes = UserDefaults.standard.bool(forKey: "showOtherVolumes") {
        didSet { UserDefaults.standard.set(showOtherVolumes, forKey: "showOtherVolumes"); normalizeSelection() }
    }
    var automaticRefresh = UserDefaults.standard.object(forKey: "automaticRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticRefresh, forKey: "automaticRefresh") }
    }
    private let disks = DiskService()
    private var isQueryingExtension = false
    private var ejectedMedia = EjectedMediaSession()

    var volumes: [VolumeRecord] { VolumeRecord.visible(records.filter { !ejectedMedia.contains($0) }, includeOtherVolumes: showOtherVolumes) }
    var ntfsVolumes: [VolumeRecord] { VolumeRecord.visible(records.filter { !ejectedMedia.contains($0) }, includeOtherVolumes: false) }
    var selectedVolume: VolumeRecord? { volumes.first { $0.id == selectedID } }
    var isBusy: Bool { isRefreshing || isOperating }

    func refresh() async {
        guard !isBusy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await disks.snapshot()
            apply(snapshot)
            errorMessage = nil
        } catch {
            inventoryIsCurrent = false
            operationMessage = nil
            errorMessage = "刷新失败，正在显示上次读取的结果。\n\(error.localizedDescription)"
        }
        refreshMountHelperStatus()
        // 系统扩展诊断可能延迟；它不应锁住已经完成清单核对的弹出或服务操作。
        // 同时只保留一项诊断查询，避免自动刷新堆积系统请求。
        if !isQueryingExtension {
            isQueryingExtension = true
            Task { [weak self] in
                let diagnostic = await ExtensionDiagnostic.load()
                self?.extensionDiagnostic = diagnostic
                self?.isQueryingExtension = false
            }
        }
    }

    func refreshMountHelperStatus() {
        let state = SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).status
        mountHelperEnabled = state == .enabled
        mountHelperNeedsApproval = state == .requiresApproval
        switch state {
        case .enabled: mountHelperStatus = "已获系统授权"
        case .requiresApproval: mountHelperStatus = "等待管理员在系统设置中批准"
        case .notRegistered: mountHelperStatus = "尚未配置"
        case .notFound: mountHelperStatus = "系统尚未识别挂载服务"
        @unknown default: mountHelperStatus = "系统返回未知状态"
        }
    }

    func registerMountHelper() {
        do {
            try SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).register()
            errorMessage = nil
        } catch { errorMessage = "挂载服务配置未完成：\(error.localizedDescription)" }
        refreshMountHelperStatus()
        // 系统可能在登记成功但尚待批准时返回权限错误；此时展示真实的待批准状态。
        if mountHelperNeedsApproval { errorMessage = nil }
    }

    func openMountHelperApproval() { SMAppService.openSystemSettingsLoginItems() }

    func unregisterMountHelper() async {
        guard !isBusy else { return }
        isOperating = true
        defer { isOperating = false; refreshMountHelperStatus() }
        do {
            let snapshot = try await disks.snapshot()
            guard snapshot.unreadableCount == 0,
                  !snapshot.records.contains(where: { $0.mountPoint?.hasPrefix(PrivilegedMountConfiguration.namespace + "/") == true }) else {
                throw DiskOperationError(message: "请先正常卸载所有受管理员服务管理的卷，再移除服务。")
            }
            try await SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).unregister()
            errorMessage = nil
        } catch { errorMessage = "挂载服务尚未移除：\(error.localizedDescription)" }
    }

    func openInFinder(_ volume: VolumeRecord) async {
        guard !isBusy, inventoryIsCurrent else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            guard let current = try await disks.record(volume.id),
                  volume.matchesMediaIdentity(of: current), volume.mountedFileSystem != nil,
                  volume.mountedFileSystem == current.mountedFileSystem,
                  let path = current.mountPoint else {
                throw DiskOperationError(message: "磁盘状态已变化，请刷新后重试。")
            }
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                throw DiskOperationError(message: "无法在 Finder 中打开此卷。")
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func eject(_ volume: VolumeRecord) async {
        guard !isBusy, inventoryIsCurrent else { return }
        isOperating = true
        operationMessage = nil
        defer { isOperating = false }
        do {
            let receipt = try await disks.eject(volume)
            let snapshot = try await disks.snapshot()
            apply(snapshot)
            if let reason = EjectVerification.unconfirmedReason(expected: volume, records: snapshot.records,
                                                               unreadableCount: snapshot.unreadableCount, receipt: receipt) {
                throw DiskOperationError(message: reason)
            }
            ejectedMedia.remember(receipt)
            normalizeSelection()
            operationMessage = receipt.message
            errorMessage = nil
        } catch {
            inventoryIsCurrent = false
            errorMessage = error is CancellationError ? "操作已取消，请刷新确认当前磁盘状态。" : error.localizedDescription
        }
    }

    func mount(_ volume: VolumeRecord, readOnly: Bool) async {
        guard !isBusy, inventoryIsCurrent, !ejectedMedia.contains(volume) else { return }
        guard extensionDiagnostic.isEnabled else {
            errorMessage = "请先在系统设置 → 通用 → 登录项与扩展 → 按类别 → 文件系统扩展中启用 NTFSFileSystem。"
            return
        }
        isOperating = true
        operationMessage = nil
        defer { isOperating = false }
        do {
            try await disks.mount(volume, readOnly: readOnly)
            apply(try await disks.snapshot())
            operationMessage = readOnly ? "已由 NTFS 畅写以只读方式挂载。" : "已由 NTFS 畅写以读写方式挂载。"
            errorMessage = nil
        } catch {
            inventoryIsCurrent = false
            errorMessage = error.localizedDescription
        }
    }

    func unmount(_ volume: VolumeRecord) async {
        guard !isBusy, inventoryIsCurrent else { return }
        isOperating = true
        operationMessage = nil
        defer { isOperating = false }
        do {
            try await disks.unmount(volume)
            apply(try await disks.snapshot())
            operationMessage = "卷已卸载，整盘仍连接。需要断开设备时，请点击“安全弹出整盘”。"
            errorMessage = nil
        } catch {
            inventoryIsCurrent = false
            errorMessage = error.localizedDescription
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出本地诊断"
        panel.nameFieldStringValue = "NTFS畅写-诊断.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        NTFS 畅写 · NTFS WriteFlow
        版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")）预览版
        读写引擎：NTFS-3G（FSKit 适配）
        生成时间：\(Date().formatted())
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        扩展状态：\(extensionDiagnostic.title)
        扩展详情：\(extensionDiagnostic.detail)
        可见文件系统卷数：\(records.filter(\.isVolume).count)
        NTFS 卷数：\(ntfsVolumes.count)
        无法读取的设备数：\(unreadableCount)
        状态是否为本次有效读取：\(inventoryIsCurrent ? "是" : "否")
        验证范围：以本版本发布说明为准；历史测试不代表本次运行已验收
        说明：此文件不包含卷名、挂载路径、卷标识、账户或用户文件内容。
        """
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "诊断保存失败：\(error.localizedDescription)" }
    }

    private func apply(_ snapshot: DiskSnapshot) {
        let revoked = ejectedMedia.reconcile(records: snapshot.records, unreadableCount: snapshot.unreadableCount)
        if revoked || snapshot.unreadableCount > 0 { operationMessage = nil }
        records = snapshot.records
        unreadableCount = snapshot.unreadableCount
        inventoryIsCurrent = true
        lastRefresh = Date()
        normalizeSelection()
    }

    private func normalizeSelection() {
        if !volumes.contains(where: { $0.id == selectedID }) { selectedID = volumes.first?.id }
    }
}
