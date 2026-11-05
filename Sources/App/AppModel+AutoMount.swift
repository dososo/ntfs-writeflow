import AppKit
import CoreGraphics
import Foundation

// 生产系统边界可注入，以测试真正AppModel事件→协调→挂载回读链。
@MainActor struct AutoMountRuntime {
    var record: (String) async throws -> VolumeRecord?
    var mount: (VolumeRecord, Bool) async throws -> Void
    var environment: () async -> AutoMountEnvironment
    var sessionAllowed: (() -> Bool)? = nil
    var loginState: (() -> LoginLaunchState)? = nil
    var sessionSnapshot: (() -> AutoMountSessionSnapshot)? = nil
}

extension AppModel {
    func startMonitoring(launchedAtLogin: Bool = false) async {
        guard diskMonitor == nil else { return }
        autoMonitorEpoch &+= 1
        let epoch = autoMonitorEpoch
        self.loginRegistrationRequired = launchedAtLogin
        refreshLoginStatus()
        startAutomaticSessionMonitoring()
        observeAutomaticSessionSnapshot()
        let monitor = DiskEventMonitor(onEvent: { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.autoMonitorEpoch == epoch, self.diskMonitor != nil else { return }
                await self.processAutoEvent(event)
            }
        }, onReady: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.autoMonitorEpoch == epoch, self.diskMonitor != nil else { return }
                self.updateAutomaticApproval()
            }
        })
        diskMonitor = monitor
        guard monitor.start() else { autoStatus = "无法建立系统磁盘事件会话。"; diskMonitor = nil; return }
        await refresh()
        guard autoMonitorEpoch == epoch, diskMonitor === monitor else { return }
        await refreshAutoEnvironment()
    }

    func stopMonitoring() {
        autoMonitorEpoch &+= 1
        autoEnvironmentQueryID &+= 1
        revokeAutomaticSession()
        for id in autoGenerations.keys { autoCoordinator.disappeared(mediaID: id) }
        autoGenerations.removeAll(); autoNative.removeAll(); autoCanonical.removeAll()
        autoSuppressedMedia.removeAll(); autoSuppressedWholeMedia.removeAll()
        diskMonitor?.stop(); diskMonitor = nil
        autoSessionMonitorEpoch &+= 1
        autoSessionMonitor?.stop(); autoSessionMonitor = nil
        autoStatus = autoIsOperating ? "监控已停止，已提交操作仍在核对。" : "自动挂载监控已停止。"
    }

    func refreshLoginStatus() {
        if let runtime = autoRuntime {
            if let state = runtime.loginState { applyLoginState(state()) }
        } else { applyLoginState(LoginLaunchService.state) }
    }
    func applyLoginState(_ state: LoginLaunchState) {
        let revoked = loginState.isEnabled && !state.isEnabled
        let loginLaunchRejected = loginRegistrationRequired && !state.isEnabled && autoEnabled
        loginState = state
        if revoked || loginLaunchRejected {
            autoEnabled = false
            autoStatus = "登录启动已被关闭或不可确认，自动管理已停止。"
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        if !enabled && autoEnabled {
            autoEnabled = false
            autoStatus = "已停止自动管理；登录项关闭结果见下方状态。"
        }
        do { try LoginLaunchService.setEnabled(enabled) }
        catch { errorMessage = "登录启动设置失败：\(error.localizedDescription)" }
        refreshLoginStatus()
        recordSessionVerification("登录设置变化")
    }

    func autoMode(for volume: VolumeRecord) -> AutoMountMode {
        guard let id = volume.mediaRegistryID else { return .off }
        return autoPolicyStore.mode(for: autoCanonical[id])
    }
    func canRememberAutoWrite(_ volume: VolumeRecord) -> Bool {
        guard let id = volume.mediaRegistryID else { return false }
        return volume.isInternal == false && volume.isNTFS && autoCanonical[id]?.permitsRememberedWrite == true
    }
    func setAutoMode(_ mode: AutoMountMode, volume: VolumeRecord) {
        guard let id = volume.mediaRegistryID, let fingerprint = autoCanonical[id],
              volume.isInternal == false, volume.isNTFS,
              mode == .off || fingerprint.permitsRememberedWrite,
              autoPolicyStore.setMode(mode, for: fingerprint) else {
            errorMessage = "缺少可记住的介质指纹，不能为此盘保存自动策略。"; return
        }
        autoSuppressedMedia.insert(id)
        autoCoordinator.suppress(mediaID: id)
        autoPending.removeValue(forKey: id)
        diskMonitor?.suppress(mediaID: id)
        // 用户在界面作出选择是解锁状态的辅助依据；登录后台状态未知时不会推定解锁。
        requestAutomaticForegroundConfirmation()
        updateAutomaticApproval()
        autoStatus = "已保存\(mode.title)，下次新接入时生效；当前挂载不会被接管。"
    }

    func cancelAutomaticWork() {
        autoPolicyEpoch &+= 1
        autoCoordinator.cancelPending()
        autoPending.removeAll()
        diskMonitor?.setApprovalRules([], authorizationEpoch: autoPolicyEpoch)
    }
    func suppressAutomatic(for volume: VolumeRecord) {
        if let whole = volume.wholeMediaRegistryID { autoSuppressedWholeMedia.insert(whole) }
        for record in records where record.wholeDiskID == volume.wholeDiskID {
            if let id = record.mediaRegistryID {
                autoSuppressedMedia.insert(id)
                diskMonitor?.suppress(mediaID: id)
                autoCoordinator.suppress(mediaID: id); autoPending.removeValue(forKey: id)
            }
        }
        if let id = volume.mediaRegistryID {
            autoSuppressedMedia.insert(id)
            diskMonitor?.suppress(mediaID: id)
            autoCoordinator.suppress(mediaID: id); autoPending.removeValue(forKey: id)
        }
    }

    func refreshAutoEnvironment() async {
        refreshLoginStatus()
        autoEnvironmentQueryID &+= 1
        let query = autoEnvironmentQueryID
        let enabledBefore = autoEnabled
        let epoch = autoMonitorEpoch
        let environment: AutoMountEnvironment
        if let runtime = autoRuntime { environment = await runtime.environment() }
        else { environment = await AutoMountEnvironment.load() }
        guard epoch == autoMonitorEpoch, query == autoEnvironmentQueryID else { return }
        autoEnvironment = environment
        guard enabledBefore == autoEnabled else { updateAutomaticApproval(); return }
        if autoEnabled && !autoIsOperating {
            autoStatus = !environment.isClear ? environment.reason : automaticSessionAllowed() ? "自动挂载监控中，仅处理已授权的新接入盘。" : "会话状态尚未核实，请打开应用确认。"
        }
        updateAutomaticApproval()
    }

    // willFinishLaunching先订阅，防止漏掉非活动用户启动时的初始会话失活通知。
    func startAutomaticSessionMonitoring(appCenter: NotificationCenter = .default,
                                         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
                                         distributedCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        guard autoSessionMonitor == nil else { return }
        autoSessionMonitorEpoch &+= 1
        let epoch = autoSessionMonitorEpoch
        autoSession = AutoMountSessionState()
        let initial = currentAutomaticSessionSnapshot()
        autoSession.setWorkspaceActive(initial.consoleUserCurrent)
        observeAutomaticSessionSnapshot()
        let monitor = AutoMountSessionMonitor(appCenter: appCenter, workspaceCenter: workspaceCenter,
            distributedCenter: distributedCenter) { [weak self] event in
                guard let self, self.autoSessionMonitorEpoch == epoch, self.autoSessionMonitor != nil else { return }
                self.receiveAutomaticSessionEvent(event)
            }
        autoSessionMonitor = monitor
        monitor.start()
    }
    private func receiveAutomaticSessionEvent(_ event: AutoMountSessionEvent) {
        observeAutomaticSessionSnapshot()
        switch event {
        case .foreground: completeAutomaticForegroundRequest()
        case .workspaceResigned: autoSession.setWorkspaceActive(false); revokeAutomaticSession()
        case .workspaceActive: autoSession.setWorkspaceActive(true); revokeAutomaticSession()
        case .willSleep: autoSession.setSleeping(true); revokeAutomaticSession()
        case .didWake: autoSession.setSleeping(false); revokeAutomaticSession()
        case .protectedDataUnavailable: observeAutomaticProtectedData(available:false); revokeAutomaticSession()
        case .protectedDataAvailable:
            autoSession.protectedDataBecameAvailable(available:currentAutomaticSessionSnapshot().protectedDataAvailable)
            revokeAutomaticSession()
        case .screenLocked: revokeAutomaticSession()
        case .screenUnlocked: break // 非可信解锁通知不能授予权限。
        }
        observeAutomaticSessionSnapshot()
        recordSessionVerification("会话信号",signal:String(describing:event))
        switch event {
        case .workspaceResigned, .workspaceActive:
            scheduleSessionVerificationSamples(event:"会话窗口采样",signal:String(describing:event))
        default: break
        }
        refreshAutomaticSessionEnvironment(epoch:autoMonitorEpoch)
    }
    private func currentAutomaticSessionSnapshot() -> AutoMountSessionSnapshot {
        if let snapshot = autoRuntime?.sessionSnapshot { return snapshot() }
        return AutoMountSessionSnapshot(applicationActive:NSApp.isActive, consoleUserCurrent:consoleUserIsCurrent(),
            protectedDataAvailable:NSApp.isProtectedDataAvailable)
    }
    @discardableResult private func observeAutomaticSessionSnapshot() -> AutoMountSessionSnapshot {
        let snapshot = currentAutomaticSessionSnapshot()
        let confirmed = autoSession.foregroundConfirmed
        let invalidatesRequest = autoForegroundRequest != nil && (!snapshot.consoleUserCurrent || !snapshot.protectedDataAvailable)
        autoSession.observeProtectedData(available:snapshot.protectedDataAvailable)
        autoSession.observeConsoleUser(current:snapshot.consoleUserCurrent)
        if invalidatesRequest || (confirmed && !autoSession.foregroundConfirmed) { revokeAutomaticSession() }
        return snapshot
    }
    private func refreshAutomaticSessionEnvironment(epoch: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.autoMonitorEpoch == epoch, self.diskMonitor != nil else { return }
            await self.refreshAutoEnvironment()
        }
    }
    func observeAutomaticProtectedData(available: Bool) {
        let revoked = !available && (autoSession.protectedDataAvailable || autoSession.foregroundConfirmed)
        autoSession.observeProtectedData(available: available)
        if revoked { revokeAutomaticSession() }
    }
    func revokeAutomaticSession() {
        autoSessionRevocationEpoch &+= 1
        autoForegroundRequest = nil
        autoSession.revoke()
        cancelAutomaticWork()
    }
    // 仅普通用户启动、reopen、菜单或明确确认按钮调用；系统激活/解锁不创建请求。
    func requestAutomaticForegroundConfirmation() {
        defer { recordSessionVerification("主动确认请求") }
        let snapshot = observeAutomaticSessionSnapshot()
        guard autoSessionMonitor != nil, snapshot.consoleUserCurrent, snapshot.protectedDataAvailable,
              !autoSession.protectedDataBlocked, !autoSession.sleeping, autoSession.workspaceActive else {
            autoForegroundRequest = nil; return
        }
        autoForegroundRequest = (autoSessionRevocationEpoch, ProcessInfo.processInfo.systemUptime + 5)
        completeAutomaticForegroundRequest()
        refreshAutomaticSessionEnvironment(epoch:autoMonitorEpoch)
    }
    private func completeAutomaticForegroundRequest() {
        guard let request = autoForegroundRequest, request.epoch == autoSessionRevocationEpoch,
              ProcessInfo.processInfo.systemUptime <= request.deadline else {
            autoForegroundRequest = nil; return
        }
        let snapshot = observeAutomaticSessionSnapshot()
        guard autoForegroundRequest != nil else { return }
        autoSession.confirmForeground(applicationActive:snapshot.applicationActive, consoleUserCurrent:snapshot.consoleUserCurrent,
            protectedDataAvailable:snapshot.protectedDataAvailable)
        if snapshot.applicationActive { autoForegroundRequest = nil }
        // 此前登录项撤销导致的总开关OFF不会恢复。
        if autoSession.foregroundConfirmed { loginRegistrationRequired = false }
    }
    var automaticSessionStatus: String {
        if autoSession.sleeping { return "系统睡眠期间暂停，唤醒后需要重新确认。" }
        if !autoSession.workspaceActive { return "当前用户会话未活动，返回后需要重新确认。" }
        if autoSession.protectedDataBlocked { return "受保护数据尚未恢复，暂不能确认会话。" }
        return autoSession.foregroundConfirmed ? "当前会话已确认；锁定、睡眠或切换用户后失效。" : "当前会话未确认，请主动打开应用或点击确认。"
    }

    private func consoleUserIsCurrent() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              (dictionary[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == geteuid(),
              dictionary[kCGSessionOnConsoleKey as String] as? Bool == true,
              dictionary[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return true
    }
    private func automaticSessionAllowed() -> Bool {
        if let runtime = autoRuntime, runtime.sessionSnapshot == nil, let allowed = runtime.sessionAllowed { return allowed() }
        let snapshot = observeAutomaticSessionSnapshot()
        return autoSession.permits(consoleUserCurrent:snapshot.consoleUserCurrent)
    }
    private func automaticContext() -> AutoMountContext {
        let session = automaticSessionAllowed()
        return AutoMountContext(enabled: autoEnabled, consoleUserActive: session, sessionUnlocked: session,
            extensionReady: extensionDiagnostic.isEnabled, helperReady: mountHelperEnabled,
            competition: autoEnvironment.isClear ? .clear : .unknown)
    }
    func updateAutomaticApproval() {
        refreshLoginStatus()
        let context = automaticContext()
        guard context.enabled, context.consoleUserActive, context.sessionUnlocked,
              context.extensionReady, context.helperReady, context.competition == .clear else {
            diskMonitor?.setApprovalRules([], authorizationEpoch: autoPolicyEpoch); return
        }
        diskMonitor?.setApprovalRules(autoPolicyStore.savedRules.filter { $0.mode != .off }.map {
            DiskAutoApprovalRule(volumeUUID: $0.fingerprint.volumeUUID, mediaSize: $0.fingerprint.mediaByteCount,
                                deviceGUID: $0.fingerprint.deviceGUID)
        }, authorizationEpoch: autoPolicyEpoch)
    }

    func processAutoEvent(_ event: DiskEvent) async {
        let eventEpoch = autoMonitorEpoch
        let policyEpoch = autoPolicyEpoch
        guard let id = event.snapshot.mediaID else { return }
        if case .disappeared = event.kind {
            recordDisappearance(mediaID: id)
            autoCoordinator.disappeared(mediaID: id)
            autoSuppressedMedia.remove(id); autoSuppressedWholeMedia.remove(id)
            autoGenerations.removeValue(forKey: id); autoNative.removeValue(forKey: id)
            autoCanonical.removeValue(forKey: id); autoPending.removeValue(forKey: id)
            return
        }
        if case .intercepted = event.kind {
            guard event.authorizationEpoch == policyEpoch, !autoSuppressedMedia.contains(id) else { return }
        }
        if autoGenerations[id] == nil { generationCounter &+= 1; autoGenerations[id] = generationCounter }
        guard let generation = autoGenerations[id] else { return }
        autoNative[id] = event.snapshot
        if autoCanonical[id] == nil, let uuid = event.snapshot.volumeUUID {
            autoCanonical[id] = AutoMountFingerprint(volumeUUID: uuid, mediaByteCount: event.snapshot.mediaSize,
                                                     deviceGUID: event.snapshot.deviceGUID)
        }
        if let existing = autoCanonical[id], existing.deviceGUID == nil,
           event.snapshot.volumeUUID?.lowercased() == existing.volumeUUID,
           event.snapshot.mediaSize == existing.mediaByteCount, let guid = event.snapshot.deviceGUID {
            autoCanonical[id] = AutoMountFingerprint(volumeUUID: existing.volumeUUID,
                mediaByteCount: existing.mediaByteCount, deviceGUID: guid)
        }
        do {
            let record = try await automaticRecord(event.snapshot.bsdName)
            guard let record, record.mediaRegistryID == id, autoGenerations[id] == generation,
                  autoMonitorEpoch == eventEpoch, autoPolicyEpoch == policyEpoch,
                  !autoSuppressedMedia.contains(id),
                  record.wholeMediaRegistryID.map({ !autoSuppressedWholeMedia.contains($0) }) ?? true else { return }
            let candidate = AutoMountCandidate(volume: record, fingerprint: autoCanonical[id], generation: generation)
            autoCoordinator.observe(candidate, initial: event.isStartup)
            if case .intercepted = event.kind, !event.isStartup { autoPending[id] = candidate }
            await drainAutomaticWork()
            if autoRuntime == nil && automaticRefresh && !isBusy { await refresh() }
        } catch {
            // 关闭、停止或启动基线的迟到查询不代表一次自动挂载失败。
            if autoEnabled, !event.isStartup, autoMonitorEpoch == eventEpoch, autoPolicyEpoch == policyEpoch,
               !autoSuppressedMedia.contains(id) {
                autoStatus = "磁盘事件后的介质核对失败，未自动操作。"
            }
        }
    }

    private func automaticRecord(_ id: String) async throws -> VolumeRecord? {
        if let runtime = autoRuntime { return try await runtime.record(id) }
        return try await disks.record(id)
    }

    func drainAutomaticWork() async {
        guard !autoPending.isEmpty, !autoIsOperating, !isOperating, !isRefreshing else { return }
        autoIsOperating = true
        defer { autoIsOperating = false }
        while let id = autoPending.keys.sorted().first, let candidate = autoPending.removeValue(forKey: id) {
            if autoRuntime == nil { refreshMountHelperStatus(); extensionDiagnostic = await ExtensionDiagnostic.load() }
            await refreshAutoEnvironment()
            let epoch = autoMonitorEpoch
            let outcome = await autoCoordinator.consider(candidate, context: automaticContext(), revalidate: { [self] in
                guard autoGenerations[id] == candidate.generation,
                      let record = try? await automaticRecord(candidate.volume.id), record.mediaRegistryID == id,
                      !autoSuppressedMedia.contains(id),
                      record.wholeMediaRegistryID.map({ !autoSuppressedWholeMedia.contains($0) }) ?? true else { return nil }
                let current = AutoMountCandidate(volume: record, fingerprint: autoCanonical[id], generation: candidate.generation)
                autoCoordinator.observe(current, initial: false)
                return (current, automaticContext())
            }, mount: { [self] value, mode in
                recordSessionVerification("请求自动挂载")
                refreshLoginStatus()
                guard autoGenerations[id] == value.generation, !autoSuppressedMedia.contains(id),
                      value.volume.wholeMediaRegistryID.map({ !autoSuppressedWholeMedia.contains($0) }) ?? true,
                      automaticSessionAllowed(), autoEnabled,
                      autoEnvironment.isClear, extensionDiagnostic.isEnabled, mountHelperEnabled,
                      autoPolicyStore.mode(for: value.fingerprint) == mode else {
                    throw DiskOperationError(message: "会话或介质已变化，未提交自动挂载。")
                }
                if let runtime = autoRuntime { try await runtime.mount(value.volume, mode == .readOnly) }
                else { try await disks.mount(value.volume, readOnly: mode == .readOnly) }
            }, verify: { [self] value, mode in
                guard autoGenerations[id] == value.generation,
                      let record = try? await automaticRecord(value.volume.id) else { return false }
                return value.volume.matchesMediaIdentity(of: record) && record.isMountedByWriteFlow
                    && record.access == (mode == .readOnly ? .readOnly : .readWrite)
            })
            if epoch == autoMonitorEpoch { autoStatus = outcome.message }
        }
        if autoRuntime == nil, let snapshot = try? await disks.snapshot() { apply(snapshot) }
    }
}
