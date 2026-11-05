import Foundation

// 系统调用由既有DiskService负责。本类只决定是否执行，并将手工与自动操作互斥。
@MainActor final class AutoMountCoordinator {
    private let store: AutoMountPolicyStore
    private var observed: [UInt64: AutoMountCandidate] = [:]
    private var retiredGeneration: [UInt64: UInt64] = [:]
    private var suppressed: [UInt64: UInt64] = [:]
    private var attempted: [UInt64: UInt64] = [:]
    private var operationInFlight = false
    private var manualOperation = false
    private var cancellationEpoch: UInt64 = 0
    private(set) var lastOutcome: AutoMountOutcome?
    var isOperating: Bool { operationInFlight || manualOperation }

    init(store: AutoMountPolicyStore) { self.store = store }

    func observe(_ candidate: AutoMountCandidate, initial: Bool) {
        guard let mediaID = candidate.volume.mediaRegistryID else { return }
        guard candidate.generation > (retiredGeneration[mediaID] ?? 0),
              candidate.generation >= (observed[mediaID]?.generation ?? 0) else { return }
        observed[mediaID] = candidate
        if initial { suppressed[mediaID] = candidate.generation }
    }
    func disappeared(mediaID: UInt64) {
        if let generation = observed[mediaID]?.generation {
            retiredGeneration[mediaID] = max(retiredGeneration[mediaID] ?? 0, generation)
        }
        observed.removeValue(forKey: mediaID)
        suppressed.removeValue(forKey: mediaID)
        attempted.removeValue(forKey: mediaID)
    }
    func suppress(mediaID: UInt64) {
        if let candidate = observed[mediaID] { suppressed[mediaID] = candidate.generation }
    }
    // 已提交的系统操作仍保持锁，直到其回包及状态核实；取消不等于系统操作结束。
    func cancelPending() {
        cancellationEpoch &+= 1
        for (id, candidate) in observed { suppressed[id] = candidate.generation }
    }
    func beginManualOperation() -> Bool {
        guard !isOperating else { return false }
        manualOperation = true
        return true
    }
    func endManualOperation() { manualOperation = false }

    func consider(_ candidate: AutoMountCandidate, context: AutoMountContext,
                  revalidate: () async -> (AutoMountCandidate, AutoMountContext)?,
                  mount: (AutoMountCandidate, AutoMountMode) async throws -> Void,
                  verify: (AutoMountCandidate, AutoMountMode) async -> Bool) async -> AutoMountOutcome {
        if let reason = rejection(candidate, context: context) { return finish(.skipped(reason)) }
        guard let id = candidate.volume.mediaRegistryID else { return finish(.skipped("介质身份不完整。")) }
        let mode = store.mode(for: candidate.fingerprint)
        let epoch = cancellationEpoch
        operationInFlight = true
        // 先保留本代名额，异步重验或命令失败也不以事件风暴反复尝试。
        attempted[id] = candidate.generation
        defer { operationInFlight = false }
        guard let (current, currentContext) = await revalidate(),
              epoch == cancellationEpoch,
              sameInsertion(candidate, current),
              rejection(current, context: currentContext, reserved: true) == nil,
              store.mode(for: current.fingerprint) == mode else {
            return finish(.unconfirmed)
        }
        do {
            try Task.checkCancellation()
            try await mount(current, mode)
            let verified = await verify(current, mode)
            guard !Task.isCancelled, epoch == cancellationEpoch,
                  let latest = observed[id], sameInsertion(current, latest),
                  suppressed[id] != candidate.generation, verified else { return finish(.unconfirmed) }
            return finish(.mounted(mode))
        } catch {
            return finish(Task.isCancelled || epoch != cancellationEpoch ? .unconfirmed : .failed(error.localizedDescription))
        }
    }

    private func rejection(_ candidate: AutoMountCandidate, context: AutoMountContext, reserved: Bool = false) -> String? {
        guard context.enabled else { return "自动挂载已关闭。" }
        guard context.consoleUserActive, context.sessionUnlocked else { return "当前用户不在活动且解锁的控制台会话。" }
        guard context.extensionReady, context.helperReady else { return "扩展或管理员挂载服务尚未就绪。" }
        guard context.competition == .clear else { return "存在竞争驱动或无法确认竞争状态，不自动接管。" }
        guard !manualOperation, reserved || !operationInFlight else { return "已有磁盘操作进行中。" }
        let volume = candidate.volume
        guard volume.canOfferMount, let id = volume.mediaRegistryID, let live = observed[id],
              sameInsertion(candidate, live) else { return "介质已变化、已挂载或不是可核实的外部NTFS。" }
        guard suppressed[id] != candidate.generation else { return "本次接入已由用户停止或属于启动已有设备。" }
        guard reserved || attempted[id] != candidate.generation else { return "本次接入已尝试，不自动重试。" }
        guard let fingerprint = candidate.fingerprint else { return "缺少持久介质标识。" }
        let mode = store.mode(for: fingerprint)
        guard mode != .off else { return "此盘未开启自动挂载。" }
        guard mode != .readWrite || (fingerprint.permitsRememberedWrite && volume.writableMedia == true) else { return "缺少可靠设备标识或未确认介质可写。" }
        let duplicates = observed.values.filter { $0.fingerprint?.volumeUUID == fingerprint.volumeUUID }
        guard duplicates.count == 1 else { return "发现重复卷标识，停止自动处理。" }
        return nil
    }
    private func sameInsertion(_ a: AutoMountCandidate, _ b: AutoMountCandidate) -> Bool {
        a.generation == b.generation && a.fingerprint == b.fingerprint && a.volume.matchesMediaIdentity(of: b.volume)
    }
    private func finish(_ outcome: AutoMountOutcome) -> AutoMountOutcome {
        lastOutcome = outcome
        return outcome
    }
}
