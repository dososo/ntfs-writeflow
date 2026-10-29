import AppKit
import Darwin
import Foundation

@MainActor private final class SessionFixture {
    var active = false, console = true, protected = true, mounted = false
    var mounts = 0, pauseRecord = false, pauseMount = false
    var held: CheckedContinuation<Void, Never>?
    let app = NotificationCenter(), workspace = NotificationCenter(), distributed = NotificationCenter()
    func record() -> VolumeRecord {
        let path = "/private/tmp/writeflow-session-fixture"
        var info: [String:Any] = ["DeviceIdentifier":"disk909", "VolumeName":"会话注入", "FilesystemType":"ntfs",
            "VolumeUUID":"session-volume", "ParentWholeDisk":"disk909", "Internal":false, "WholeDisk":true,
            "WritableMedia":true, "IOKitSize":4096]
        if mounted { info["MountPoint"] = path }
        let fs = mounted ? MountedFileSystem(type:"blntfs",source:"/dev/disk909",mountPoint:path,
            identity:"session-instance",ownerID:geteuid(),isReadOnly:false) : nil
        return VolumeRecord(info:info,mediaRegistryID:909,wholeMediaRegistryID:909,mountedFileSystem:fs)!
    }
    func model() -> AppModel {
        let runtime = AutoMountRuntime(record: { [self] _ in
            if pauseRecord { pauseRecord = false; await withCheckedContinuation { held = $0 } }
            return record()
        }, mount: { [self] _, _ in
            mounts += 1
            if pauseMount { pauseMount = false; await withCheckedContinuation { held = $0 } }
            mounted = true
        }, environment: { AutoMountEnvironment(isClear:true,reason:"注入环境") },loginState:{ .enabled },
        sessionSnapshot:{ [self] in AutoMountSessionSnapshot(applicationActive:active, consoleUserCurrent:console, protectedDataAvailable:protected) })
        let result = AppModel(defaults:UserDefaults(suiteName:"writeflow.session.\(UUID().uuidString)")!,autoMountRuntime:runtime)
        result.startAutomaticSessionMonitoring(appCenter:app,workspaceCenter:workspace,distributedCenter:distributed)
        result.autoEnabled = true; result.mountHelperEnabled = true
        result.extensionDiagnostic = ExtensionDiagnostic(title:"注入",detail:"",isEnabled:true)
        _ = result.autoPolicyStore.setMode(.readWrite,for:AutoMountFingerprint(volumeUUID:"session-volume",mediaByteCount:4096,deviceGUID:"session-guid")!)
        return result
    }
    func event(_ model: AppModel) -> DiskEvent {
        DiskEvent(kind:.intercepted,snapshot:DiskEventSnapshot(bsdName:"disk909",mediaID:909,volumeUUID:"session-volume",
            mediaSize:4096,deviceGUID:"session-guid",isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS"),
            isStartup:false,authorizationEpoch:model.autoPolicyEpoch)
    }
    func foreground() { app.post(name:NSApplication.didBecomeActiveNotification,object:nil) }
}

@main enum SessionNotificationTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        func check(_ value: Bool, _ reason: String) { if !value { print("失败：\(reason)"); exit(1) } }
        func allowed(_ m: AppModel) -> Bool { m.autoSession.permits(consoleUserCurrent:true) }
        let f = SessionFixture(), m = f.model()
        check(!allowed(m), "后台初始状态被授予")
        f.foreground(); check(!allowed(m), "非活动应用的前台通知被接受")
        f.active = true; f.foreground(); check(!allowed(m), "没有显式用户请求的激活通知重新授予会话")
        m.requestAutomaticForegroundConfirmation(); check(allowed(m), "显式用户请求未确认会话")
        f.app.post(name:.NSApplicationProtectedDataWillBecomeUnavailable,object:nil)
        m.startAutomaticSessionMonitoring(appCenter:f.app,workspaceCenter:f.workspace,distributedCenter:f.distributed)
        check(m.autoSession.protectedDataBlocked, "重复早期订阅重置了数据保护闭锁")
        f.foreground(); check(!allowed(m), "willUnavailable后属性仍true使确认复活")
        f.protected = false; f.app.post(name:.NSApplicationProtectedDataDidBecomeAvailable,object:nil)
        f.foreground(); check(!allowed(m), "恢复通知与属性不一致却允许")
        f.protected = true; f.app.post(name:.NSApplicationProtectedDataDidBecomeAvailable,object:nil)
        check(!allowed(m), "恢复通知自身授予")
        m.requestAutomaticForegroundConfirmation(); f.foreground(); check(allowed(m), "恢复后的新前台确认未接受")
        f.workspace.post(name:NSWorkspace.willSleepNotification,object:nil)
        m.startAutomaticSessionMonitoring(appCenter:f.app,workspaceCenter:f.workspace,distributedCenter:f.distributed)
        check(m.autoSession.sleeping, "重复早期订阅重置了睡眠闭锁")
        f.foreground()
        check(!allowed(m), "睡眠闭锁被前台通知绕过")
        f.workspace.post(name:NSWorkspace.didWakeNotification,object:nil)
        check(!allowed(m), "唤醒自动恢复确认")
        m.requestAutomaticForegroundConfirmation(); f.foreground(); check(allowed(m), "唤醒后的新确认失败")
        f.workspace.post(name:NSWorkspace.sessionDidResignActiveNotification,object:nil); f.foreground()
        check(!allowed(m), "非活动工作区仍可确认")
        f.workspace.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
        check(!allowed(m), "用户切回自动恢复确认")
        m.requestAutomaticForegroundConfirmation(); f.foreground(); check(allowed(m), "切回后新确认失败")
        f.distributed.post(name:Notification.Name("com.apple.screenIsLocked"),object:nil)
        f.distributed.post(name:Notification.Name("com.apple.screenIsUnlocked"),object:nil)
        check(!allowed(m), "非可信解锁通知授予")
        m.requestAutomaticForegroundConfirmation(); f.console = false; m.updateAutomaticApproval()
        f.console = true; m.updateAutomaticApproval()
        check(!allowed(m), "控制台失效后恢复复活旧确认")
        m.requestAutomaticForegroundConfirmation(); f.foreground(); check(allowed(m), "控制台恢复后新确认失败")
        let beforeStop = m.autoPolicyEpoch
        m.stopMonitoring(); f.workspace.post(name:NSWorkspace.willSleepNotification,object:nil); f.foreground()
        check(!allowed(m) && m.autoPolicyEpoch == beforeStop + 1, "停止后的旧通知仍影响模型")

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let x = SessionFixture(), model = x.model(); x.active = true; model.requestAutomaticForegroundConfirmation(); x.foreground(); x.pauseRecord = true
            let task = Task { await model.processAutoEvent(x.event(model)) }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while x.held == nil && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            check(x.held != nil, "挂起查询检查点未到达")
            x.workspace.post(name:name,object:nil); x.foreground()
            x.held?.resume(); x.held = nil; await task.value
            check(x.mounts == 0, "负向会话通知未阻止等待查询中的挂载")
            model.stopMonitoring()
        }
        let valid = SessionFixture(), activation = valid.model()
        activation.requestAutomaticForegroundConfirmation()
        check(activation.autoForegroundRequest != nil && !allowed(activation), "合法请求没有等待激活")
        valid.active = true; valid.foreground()
        check(allowed(activation) && activation.autoForegroundRequest == nil, "当前代有效请求没有被正常消费")
        activation.stopMonitoring()

        let intent = SessionFixture(), delayed = intent.model()
        delayed.requestAutomaticForegroundConfirmation()
        check(delayed.autoForegroundRequest != nil && !allowed(delayed), "未活动时请求应短时等待激活")
        intent.workspace.post(name:NSWorkspace.willSleepNotification,object:nil)
        intent.workspace.post(name:NSWorkspace.didWakeNotification,object:nil)
        intent.active = true; intent.foreground()
        check(!allowed(delayed) && delayed.autoForegroundRequest == nil, "旧用户请求越过睡眠唤醒")
        delayed.autoForegroundRequest = (delayed.autoSessionRevocationEpoch, ProcessInfo.processInfo.systemUptime - 1)
        intent.foreground(); check(!allowed(delayed), "已过期用户请求被消费")
        intent.active = false; delayed.requestAutomaticForegroundConfirmation(); intent.console = false
        delayed.updateAutomaticApproval(); intent.console = true; intent.active = true; intent.foreground()
        check(!allowed(delayed) && delayed.autoForegroundRequest == nil, "控制台失效未清除待激活请求")
        delayed.stopMonitoring()

        let pending = SessionFixture(), busy = pending.model(); pending.active = true; busy.requestAutomaticForegroundConfirmation(); pending.foreground(); pending.pauseMount = true
        let operation = Task { await busy.processAutoEvent(pending.event(busy)) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while pending.held == nil && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        check(pending.held != nil, "在途检查点未到达")
        pending.workspace.post(name:NSWorkspace.willSleepNotification,object:nil)
        check(busy.autoIsOperating && busy.isBusy, "睡眠通知提前释放已提交锁")
        pending.held?.resume(); pending.held = nil; await operation.value
        check(!busy.autoIsOperating && !busy.autoStatus.contains("已完成"), "撤销后误报成功")
        busy.stopMonitoring()
        print("真实AppModel通知接线通过：后台拒绝、9种信号、交叉闭锁、控制台失效、停止注销、两类等待撤销及在途锁；仅隔离NotificationCenter和快照/磁盘边界注入，未改变系统会话或操作磁盘。")
    }
}
