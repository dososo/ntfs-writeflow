import Foundation

@main enum AutoMountPolicyTests {
    @MainActor static func main() async {
        let domain = "自动挂载测试-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let store = AutoMountPolicyStore(defaults: defaults)
        let coordinator = AutoMountCoordinator(store: store)
        func candidate(_ media: UInt64 = 101, generation: UInt64 = 1, guid: String? = "设备GUID") -> AutoMountCandidate {
            let record = VolumeRecord(info: ["DeviceIdentifier":"disk7s1", "ParentWholeDisk":"disk7", "FilesystemType":"ntfs", "VolumeUUID":"卷UUID", "Internal":false, "IOKitSize":Int64(1_000_000), "WritableMedia":true], mediaRegistryID: media, wholeMediaRegistryID: media + 1)!
            return AutoMountCandidate(volume: record, fingerprint: AutoMountFingerprint(volumeUUID:"卷UUID",mediaByteCount:1_000_000,deviceGUID:guid),generation:generation)
        }
        let ready = AutoMountContext(enabled:true,consoleUserActive:true,sessionUnlocked:true,extensionReady:true,helperReady:true,competition:.clear)
        var calls = 0
        let first = candidate()
        coordinator.observe(first, initial:false)
        var outcome = await coordinator.consider(first, context:ready, revalidate:{(first,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 0 && outcome != .mounted(.readWrite), "默认逐盘关闭")
        store.setMode(.readWrite, for:first.fingerprint!)
        let saved = AutoMountPolicyStore(defaults: defaults)
        check(saved.mode(for:first.fingerprint) == .readWrite,"逐盘模式持久保存")
        outcome = await coordinator.consider(first, context:ready, revalidate:{(first,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(outcome == .mounted(.readWrite) && calls == 1,"已授权新接入成功")
        _ = await coordinator.consider(first, context:ready, revalidate:{(first,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"同代重复事件不重挂")
        coordinator.disappeared(mediaID:101)
        let next = candidate(generation:2)
        coordinator.observe(next, initial:false);coordinator.suppress(mediaID:101)
        _ = await coordinator.consider(next, context:ready, revalidate:{(next,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"手工卸载抑制")
        coordinator.disappeared(mediaID:101)
        let startup = candidate(generation:3)
        coordinator.observe(startup, initial:true)
        _ = await coordinator.consider(startup, context:ready, revalidate:{(startup,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"启动已有盘不自动操作")
        coordinator.disappeared(mediaID:101)
        let noGUID = candidate(generation:4,guid:nil)
        coordinator.observe(noGUID, initial:false);store.setMode(.readWrite,for:noGUID.fingerprint!)
        _ = await coordinator.consider(noGUID, context:ready, revalidate:{(noGUID,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"弱指纹不允许自动读写")
        coordinator.disappeared(mediaID:101)
        let fifth = candidate(generation:5)
        coordinator.observe(fifth,initial:false)
        let duplicate = candidate(201,generation:1)
        coordinator.observe(duplicate,initial:false)
        _ = await coordinator.consider(fifth, context:ready, revalidate:{(fifth,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"重复持久指纹拒绝")
        coordinator.disappeared(mediaID:201)
        var unknown = ready;unknown.competition = .unknown
        _ = await coordinator.consider(fifth, context:unknown, revalidate:{(fifth,unknown)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"竞争状态未知拒绝")
        check(coordinator.beginManualOperation(),"可保留手工操作锁")
        _ = await coordinator.consider(fifth, context:ready, revalidate:{(fifth,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1,"手工与自动互斥");coordinator.endManualOperation()
        outcome = await coordinator.consider(fifth, context:ready, revalidate:{
            coordinator.disappeared(mediaID:101);return (fifth,ready)
        }, mount:{_,_ in calls += 1}, verify:{_,_ in true})
        check(calls == 1 && outcome != .mounted(.readWrite),"异步核验后旧介质失效")
        let sixth = candidate(generation:6);coordinator.observe(sixth,initial:false)
        outcome = await coordinator.consider(sixth, context:ready, revalidate:{(sixth,ready)}, mount:{_,_ in
            calls += 1;coordinator.disappeared(mediaID:101)
        }, verify:{_,_ in true})
        check(calls == 2 && outcome == .unconfirmed,"已提交后移除不误报成功")
        let seventh = candidate(generation:7);coordinator.observe(seventh,initial:false)
        outcome = await coordinator.consider(seventh, context:ready, revalidate:{(seventh,ready)}, mount:{_,_ in calls += 1}, verify:{_,_ in false})
        check(outcome == .unconfirmed,"挂载回读不符不报成功")
        let blockedContexts:[AutoMountContext] = [
            AutoMountContext(enabled:false,consoleUserActive:true,sessionUnlocked:true,extensionReady:true,helperReady:true,competition:.clear),
            AutoMountContext(enabled:true,consoleUserActive:false,sessionUnlocked:true,extensionReady:true,helperReady:true,competition:.clear),
            AutoMountContext(enabled:true,consoleUserActive:true,sessionUnlocked:false,extensionReady:true,helperReady:true,competition:.clear),
            AutoMountContext(enabled:true,consoleUserActive:true,sessionUnlocked:true,extensionReady:false,helperReady:true,competition:.clear),
            AutoMountContext(enabled:true,consoleUserActive:true,sessionUnlocked:true,extensionReady:true,helperReady:false,competition:.clear)]
        for (index,context) in blockedContexts.enumerated() {
            coordinator.disappeared(mediaID:101);let c=candidate(generation:UInt64(8+index));coordinator.observe(c,initial:false)
            let before=calls
            _ = await coordinator.consider(c,context:context,revalidate:{(c,context)},mount:{_,_ in calls += 1},verify:{_,_ in true})
            check(before == calls,"总开关/控制台/锁屏/扩展/助手门禁")
        }
        coordinator.disappeared(mediaID:101)
        let retired = candidate(generation:12)
        coordinator.observe(retired,initial:false)
        let prior = calls
        _ = await coordinator.consider(retired,context:ready,revalidate:{(retired,ready)},mount:{_,_ in calls += 1},verify:{_,_ in true})
        check(prior == calls,"移除后的迟到同代事件不能复活任务")
        let pending = candidate(401,generation:1)
        coordinator.observe(pending,initial:false)
        var completion: CheckedContinuation<Void,Never>?
        let task = Task { @MainActor in
            await coordinator.consider(pending,context:ready,revalidate:{(pending,ready)},mount:{_,_ in
                await withCheckedContinuation { completion = $0 }
            },verify:{_,_ in true})
        }
        while completion == nil { await Task.yield() }
        check(!coordinator.beginManualOperation(),"系统操作未结束时拒绝手工并发")
        coordinator.cancelPending()
        check(!coordinator.beginManualOperation(),"取消不提前解锁仍执行中的系统命令")
        completion?.resume()
        let cancelledOutcome = await task.value
        check(cancelledOutcome == .unconfirmed && coordinator.beginManualOperation(),"核实结束后才解锁且不误报取消成功")
        coordinator.endManualOperation()
        defaults.set(Data([0xff]),forKey:"writeflow.autoMountPolicies.v1")
        let malformed = AutoMountPolicyStore(defaults:defaults)
        check(malformed.loadFailed && malformed.mode(for:first.fingerprint) == .off,"损坏政策数据不启用挂载")
        defaults.removePersistentDomain(forName:domain)
        print("通过：24项逐盘政策、持久化、身份、接入代、取消、互斥及结果核实检查；未操作设备。")
    }
    static func check(_ ok: Bool,_ message:String) {precondition(ok,message)}
}
