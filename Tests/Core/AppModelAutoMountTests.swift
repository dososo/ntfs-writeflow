import Foundation
import AppKit
@MainActor private final class Fixture {
 var mounts = 0
 var mounted = false
 var held: CheckedContinuation<Void, Never>?
 var pause = false
 var pauseRecord = false
 var heldRecord: CheckedContinuation<Void, Never>?
 var failRecord = false
 func record() -> VolumeRecord {
  var info: [String: Any] = ["DeviceIdentifier":"disk99", "VolumeName":"测试", "FilesystemType":"ntfs", "VolumeUUID":"volume", "ParentWholeDisk":"disk99", "Internal":false, "WholeDisk":true, "WritableMedia":true, "IOKitSize":4096]
  let path = "/private/tmp/owned-test"
  if mounted { info["MountPoint"] = path }
  let fs = mounted ? MountedFileSystem(type:"blntfs",source:"/dev/disk99",mountPoint:path,identity:"test-instance",ownerID:501,isReadOnly:false) : nil
  return VolumeRecord(info:info,mediaRegistryID:99,wholeMediaRegistryID:99,mountedFileSystem:fs)!
 }
 var event: DiskEventSnapshot { DiskEventSnapshot(bsdName:"disk99",mediaID:99,volumeUUID:"volume",mediaSize:4096,deviceGUID:"guid",isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS") }
}
@main enum AppModelAutoMountTests {
 @MainActor static func main() async {
  _ = NSApplication.shared
  let defaults = UserDefaults(suiteName:"writeflow.auto.integration.\(UUID().uuidString)")!
  let fixture = Fixture()
  let runtime = AutoMountRuntime(record:{ _ in
   if fixture.pauseRecord {
    fixture.pauseRecord = false
    await withCheckedContinuation { fixture.heldRecord = $0 }
   }
   if fixture.failRecord { throw DiskOperationError(message:"模拟设备已移除") }
   return fixture.record()
  },mount:{ _, _ in
   fixture.mounts += 1
   if fixture.pause { await withCheckedContinuation { fixture.held = $0 } }
   fixture.mounted = true
  }, environment:{ AutoMountEnvironment(isClear:true,reason:"模拟已核验环境") },sessionAllowed:{ true })
  let model = AppModel(defaults:defaults,autoMountRuntime:runtime)
  precondition(!model.autoEnabled)
  model.autoEnabled = true
  model.extensionDiagnostic = ExtensionDiagnostic(title:"测试",detail:"",isEnabled:true)
  model.mountHelperEnabled = true
  let fingerprint = AutoMountFingerprint(volumeUUID:"volume",mediaByteCount:4096,deviceGUID:"guid")!
  precondition(model.autoPolicyStore.setMode(.readWrite,for:fingerprint))
  await model.processAutoEvent(DiskEvent(kind:.appeared,snapshot:fixture.event,isStartup:true))
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(fixture.mounts == 0,"启动重放事件不应发起挂载")
  await model.processAutoEvent(DiskEvent(kind:.disappeared,snapshot:fixture.event,isStartup:false))
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(fixture.mounts == 1 && model.autoStatus.contains("已完成"),"原生事件没有走实际协调和挂载回读")
  fixture.mounted = false
  model.suppressAutomatic(for:fixture.record())
  await model.processAutoEvent(DiskEvent(kind:.changed,snapshot:fixture.event,isStartup:false))
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(fixture.mounts == 1,"手工卸载后不应自动重挂")
  await model.processAutoEvent(DiskEvent(kind:.disappeared,snapshot:fixture.event,isStartup:false))
  fixture.pause = true
  let task = Task { await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch)) }
  while fixture.held == nil { await Task.yield() }
  model.autoEnabled = false
  precondition(model.autoIsOperating && model.isBusy,"撤销策略不应提前释放未决系统操作锁")
  fixture.held?.resume(); fixture.held = nil
  await task.value
  precondition(!model.autoIsOperating && !model.autoStatus.contains("已完成"),"取消后不应误报成功")
  model.stopMonitoring()
  precondition(model.autoGenerations.isEmpty && model.autoCanonical.isEmpty && model.autoNative.isEmpty,"停止后不得留下幽灵设备")
  fixture.pause = false
  fixture.mounted = false
  model.autoEnabled = true
  model.isOperating = true
  let before = fixture.mounts
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(fixture.mounts == before && model.autoPending.count == 1)
  model.isOperating = false
  for _ in 0..<2000 {
   if fixture.mounts == before + 1 && !model.autoIsOperating { break }
   try? await Task.sleep(for:.milliseconds(1))
  }
  precondition(fixture.mounts == before + 1,"业务锁释放未自动处理排队磁盘")
  model.stopMonitoring()
  model.autoEnabled = false
  fixture.failRecord = true
  await model.processAutoEvent(DiskEvent(kind:.changed,snapshot:fixture.event,isStartup:false))
  precondition(model.autoStatus == "自动挂载已关闭。", "关闭时迟到的查询失败不得覆盖关闭状态")
  model.autoEnabled = true
  model.autoStatus = "启动基线观察中"
  await model.processAutoEvent(DiskEvent(kind:.appeared,snapshot:fixture.event,isStartup:true))
  precondition(model.autoStatus == "启动基线观察中", "启动基线查询失败不能冒充自动挂载事务失败")
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(model.autoStatus.contains("核对失败"), "真正的新接入查询失败仍须可见")
  model.stopMonitoring()
  fixture.failRecord = false
  for action in ["关闭再开启", "手动抑制", "会话撤销", "设置变更", "其他盘手动抑制", "同整盘分卷抑制", "同整盘未入清单分卷"] {
   fixture.mounted = false
   fixture.pauseRecord = true
   model.autoEnabled = true
   let beforeLate = fixture.mounts
   let late = Task { await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch)) }
   while fixture.heldRecord == nil { await Task.yield() }
   let sibling = VolumeRecord(info:["DeviceIdentifier":"disk99s2","VolumeName":"仅模拟分卷","FilesystemType":"ntfs","VolumeUUID":"sibling","ParentWholeDisk":"disk99","Internal":false,"WholeDisk":false,"WritableMedia":true,"IOKitSize":4096],mediaRegistryID:100,wholeMediaRegistryID:99)!
   let other = VolumeRecord(info:["DeviceIdentifier":"disk100","VolumeName":"仅模拟其他盘","FilesystemType":"ntfs","VolumeUUID":"other","ParentWholeDisk":"disk100","Internal":false,"WholeDisk":true,"WritableMedia":true,"IOKitSize":4096],mediaRegistryID:100,wholeMediaRegistryID:100)!
   switch action {
   case "关闭再开启": model.autoEnabled = false; model.autoEnabled = true
   case "手动抑制": model.suppressAutomatic(for:fixture.record())
   case "会话撤销": model.cancelAutomaticWork()
   case "其他盘手动抑制": model.suppressAutomatic(for:other)
   case "同整盘分卷抑制": model.records = [fixture.record(),sibling]; model.suppressAutomatic(for:sibling)
   case "同整盘未入清单分卷": model.records = []; model.suppressAutomatic(for:sibling)
   default: model.setAutoMode(.off,volume:fixture.record()); model.setAutoMode(.readWrite,volume:fixture.record())
   }
   fixture.heldRecord?.resume(); fixture.heldRecord = nil
   await late.value
   let expected = action == "其他盘手动抑制" ? beforeLate + 1 : beforeLate
   precondition(fixture.mounts == expected,"\(action)后迟到事件处理不正确")
   model.stopMonitoring()
  }
  fixture.mounted = false
  model.autoEnabled = true
  model.isOperating = true
  let beforeSiblingPending = fixture.mounts
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
  precondition(model.autoPending.count == 1)
  model.records = []
  let pendingSibling = VolumeRecord(info:["DeviceIdentifier":"disk99s2","VolumeName":"仅模拟分卷","FilesystemType":"ntfs","VolumeUUID":"sibling","ParentWholeDisk":"disk99","Internal":false,"WholeDisk":false,"WritableMedia":true,"IOKitSize":4096],mediaRegistryID:100,wholeMediaRegistryID:99)!
  model.suppressAutomatic(for:pendingSibling)
  model.isOperating = false
  for _ in 0..<2000 {
   if model.autoPending.isEmpty && !model.autoIsOperating { break }
   try? await Task.sleep(for:.milliseconds(1))
  }
  precondition(fixture.mounts == beforeSiblingPending,"清单尚未包含同盘分卷时排队事务仍须服从整盘抑制")
  model.stopMonitoring()
  // 第一窗：事件已经生成，但模型任务尚未开始；第二窗：回调已经读到旧规则，稍后才生成事件。
  for oldEventAlreadyCreated in [true,false] {
   fixture.mounted = false
   model.autoEnabled = true
   let oldAuthorization = model.autoPolicyEpoch
   let queued = DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:oldAuthorization)
   let beforeQueued = fixture.mounts
   model.autoEnabled = false; model.autoEnabled = true
   let delayed = oldEventAlreadyCreated ? queued : DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false,authorizationEpoch:oldAuthorization)
   await model.processAutoEvent(delayed)
   precondition(fixture.mounts == beforeQueued,"原生旧规则的迟到事件不得跨撤销版本挂载")
   model.stopMonitoring()
  }
  fixture.mounted = false
  let beforeMissing = fixture.mounts
  await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:fixture.event,isStartup:false))
  precondition(fixture.mounts == beforeMissing,"缺少批准规则版本的事件应拒绝")
  model.stopMonitoring()
  model.autoStatus = "会话状态尚未核实，请打开应用确认。"
  await model.refreshAutoEnvironment()
  precondition(model.autoStatus.contains("自动挂载监控中"),"活动会话重新核验后应清除旧的未核实提示")
  print("AppModel事件集成通过：启动屏障、新接入挂载回读、手工抑制、操作中撤销不放锁、7类查询中取消与分盘边界、2类旧规则排队事件及缺令牌拒绝。未调用真实磁盘。")
 }
}
