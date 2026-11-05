import AppKit
import Foundation
import Darwin

@MainActor private final class LoginFixture {
    var mounts = 0
    var mounted = false
    var registrationState = LoginLaunchState.enabled
    var pauseRecord = false
    var pauseMount = false
    var recordCalls = 0
    var revokeAtRecord: Int?
    var held: CheckedContinuation<Void, Never>?
    func record() -> VolumeRecord {
        let path = "/private/tmp/writeflow-login-fixture"
        var info: [String: Any] = ["DeviceIdentifier":"disk901", "VolumeName":"登录策略测试", "FilesystemType":"ntfs",
            "VolumeUUID":"login-volume", "ParentWholeDisk":"disk901", "Internal":false, "WholeDisk":true,
            "WritableMedia":true, "IOKitSize":4096]
        if mounted { info["MountPoint"] = path }
        let fs = mounted ? MountedFileSystem(type:"blntfs",source:"/dev/disk901",mountPoint:path,
            identity:"login-instance",ownerID:geteuid(),isReadOnly:false) : nil
        return VolumeRecord(info:info,mediaRegistryID:901,wholeMediaRegistryID:901,mountedFileSystem:fs)!
    }
    func makeModel() -> AppModel {
        let runtime = AutoMountRuntime(record: { [self] _ in
            recordCalls += 1
            if recordCalls == revokeAtRecord { registrationState = .notRegistered }
            if pauseRecord { pauseRecord = false; await withCheckedContinuation { held = $0 } }
            return record()
        }, mount: { [self] _, _ in
            mounts += 1
            if pauseMount { pauseMount = false; await withCheckedContinuation { held = $0 } }
            mounted = true
        }, environment: { AutoMountEnvironment(isClear:true,reason:"仅注入测试环境") },sessionAllowed: { true },loginState: { [self] in registrationState })
        let model = AppModel(defaults:UserDefaults(suiteName:"writeflow.login-test.\(UUID().uuidString)")!,autoMountRuntime:runtime)
        model.autoEnabled = true
        model.mountHelperEnabled = true
        model.extensionDiagnostic = ExtensionDiagnostic(title:"测试",detail:"",isEnabled:true)
        _ = model.autoPolicyStore.setMode(.readWrite,for:AutoMountFingerprint(volumeUUID:"login-volume",mediaByteCount:4096,deviceGUID:"login-guid")!)
        return model
    }
    func event(_ model: AppModel) -> DiskEvent {
        DiskEvent(kind:.intercepted,snapshot:DiskEventSnapshot(bsdName:"disk901",mediaID:901,volumeUUID:"login-volume",
            mediaSize:4096,deviceGUID:"login-guid",isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS"),
            isStartup:false,authorizationEpoch:model.autoPolicyEpoch)
    }
}

@main enum LoginRevocationTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        func check(_ condition: Bool, _ reason: String) { if !condition { print("失败：\(reason)"); exit(1) } }
        let fixture = LoginFixture(), model = fixture.makeModel()
        model.applyLoginState(.enabled)
        fixture.pauseRecord = true
        let task = Task { await model.processAutoEvent(fixture.event(model)) }
        while fixture.held == nil { await Task.yield() }
        fixture.registrationState = .notRegistered
        fixture.held?.resume(); fixture.held = nil
        await task.value
        check(fixture.mounts == 0,"查询期间系统撤销登录项后，旧事件仍执行了挂载")
        check(!model.autoEnabled,"登录项撤销没有关闭自动管理")
        check(!model.loginEnabled && model.loginStatus == "未启用","开关和状态文本未来自同一快照")
        model.stopMonitoring()

        let finalFixture = LoginFixture(), finalModel = finalFixture.makeModel()
        finalModel.applyLoginState(.enabled); finalFixture.revokeAtRecord = 2
        await finalModel.processAutoEvent(finalFixture.event(finalModel))
        check(finalFixture.recordCalls >= 2 && finalFixture.mounts == 0 && !finalModel.autoEnabled,
              "提交前最后一次介质复核期间撤销，仍提交了挂载")
        finalModel.stopMonitoring()

        let protectedFixture = LoginFixture(), protectedModel = protectedFixture.makeModel()
        protectedModel.autoSession.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        protectedFixture.pauseRecord = true
        let protectedTask = Task { await protectedModel.processAutoEvent(protectedFixture.event(protectedModel)) }
        while protectedFixture.held == nil { await Task.yield() }
        let oldEpoch = protectedModel.autoPolicyEpoch
        protectedModel.observeAutomaticProtectedData(available:false)
        protectedModel.observeAutomaticProtectedData(available:true)
        protectedFixture.held?.resume(); protectedFixture.held = nil; await protectedTask.value
        check(protectedFixture.mounts == 0 && protectedModel.autoPolicyEpoch > oldEpoch,
              "负向数据保护信号未取消等待中的旧事件")
        check(!protectedModel.autoSession.permits(consoleUserCurrent:true), "数据重新可用恢复了旧会话")
        protectedModel.stopMonitoring()

        for state in [LoginLaunchState.requiresApproval,.notFound,.unknown] {
            let f = LoginFixture(), m = f.makeModel(); m.applyLoginState(.enabled); f.registrationState = state; m.applyLoginState(state)
            check(!m.autoEnabled,"已启用登录项变为\(state)后未停止自动管理"); m.stopMonitoring()
        }
        let manualFixture = LoginFixture(); manualFixture.registrationState = .notRegistered
        let manual = manualFixture.makeModel(); manual.applyLoginState(.notRegistered)
        check(manual.autoEnabled,"未选择登录启动的手动会话不应被误当撤销"); manual.stopMonitoring()
        let loginFixture = LoginFixture(); loginFixture.registrationState = .notRegistered
        let login = loginFixture.makeModel(); login.loginRegistrationRequired = true; login.applyLoginState(.notRegistered)
        check(!login.autoEnabled,"后台登录进程不能在登记已失效时继续自动管理"); login.stopMonitoring()

        let pending = LoginFixture(), active = pending.makeModel(); active.applyLoginState(.enabled); pending.pauseMount = true
        let operation = Task { await active.processAutoEvent(pending.event(active)) }
        while pending.held == nil { await Task.yield() }
        pending.registrationState = .notRegistered; active.applyLoginState(.notRegistered)
        check(active.autoIsOperating && active.isBusy,"登录项撤销不能提前释放已提交操作锁")
        pending.held?.resume(); pending.held = nil; await operation.value
        check(!active.autoIsOperating && !active.autoStatus.contains("已完成"),"撤销后不能误报在途操作成功")
        active.stopMonitoring()
        let protectedPending = LoginFixture(), protectedActive = protectedPending.makeModel()
        protectedActive.autoSession.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        protectedPending.pauseMount = true
        let protectedOperation = Task { await protectedActive.processAutoEvent(protectedPending.event(protectedActive)) }
        while protectedPending.held == nil { await Task.yield() }
        protectedActive.observeAutomaticProtectedData(available:false)
        check(protectedActive.autoIsOperating && protectedActive.isBusy, "数据保护撤销提前释放了在途锁")
        protectedPending.held?.resume(); protectedPending.held = nil; await protectedOperation.value
        check(!protectedActive.autoIsOperating && !protectedActive.autoStatus.contains("已完成"), "数据保护撤销后误报成功")
        protectedActive.stopMonitoring()
        print("登录项撤销模型回归通过：等待查询、登记失效、手动会话、登录会话、提交前复核、状态快照、负向数据保护和在途锁；未注册服务或操作磁盘。")
    }
}
