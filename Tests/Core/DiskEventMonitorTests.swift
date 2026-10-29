import Foundation
@main enum DiskEventMonitorTests {
 static func main() async {
  let rule = DiskAutoApprovalRule(volumeUUID: "V", mediaSize: 4096, deviceGUID: "G")
  let disk = DiskEventSnapshot(bsdName: "disk99", mediaID: 99, volumeUUID: "v", mediaSize: 4096, deviceGUID: "g", isInternal: false, volumeKind: "ntfs", mountPath: nil, contentHint: "Windows_NTFS")
  var gate = DiskApprovalGate()
  gate.rules = [rule]
  precondition(!gate.intercept(disk), "启动未就绪不能拒绝")
  gate.ready = true
  gate.baseline = [99]
  precondition(!gate.intercept(disk), "已有设备不能冒充新插入")
  gate.baseline = []
  precondition(gate.intercept(disk), "受信新盘应只拒绝一次")
  precondition(!gate.intercept(disk), "不能拒绝自有第二次挂载")
  gate.removed(99)
  precondition(gate.intercept(disk), "移除后新接入允许新事务")
  gate.ready = false
  precondition(!gate.intercept(disk))
  gate.ready = true
  gate.removed(99)
  gate.observed[100] = DiskEventSnapshot(bsdName: "disk100", mediaID: 100, volumeUUID: "v", mediaSize: 4096, deviceGUID: "different", isInternal: false, volumeKind: "ntfs", mountPath: nil, contentHint: "Windows_NTFS")
  precondition(!gate.intercept(disk), "任何相同UUID均阻断，即使GUID不同")
  gate.removed(100)
  precondition(gate.intercept(disk))
  let clear = AutoMountEnvironment.classify(filesystems: [], extensions: [], loaded: [], modules: ["com.apple.fskit.exfat", "com.blteam.ntfsworkbench.filesystem"])
  precondition(clear.isClear)
  precondition(!AutoMountEnvironment.classify(filesystems: ["ufsd_NTFS.fs"], extensions: [], loaded: [], modules: []).isClear)
  precondition(!AutoMountEnvironment.classify(filesystems: [], extensions: ["UnknownStorage.kext"], loaded: [], modules: []).isClear)
  precondition(!AutoMountEnvironment.classify(filesystems: [], extensions: [], loaded: [], modules: ["org.other.fs"]).isClear)
  precondition(AutoMountEnvironment.parseLoaded("2 0 0 0 0 io.vendor.driver (1.0)") == ["io.vendor.driver"])
  precondition(AutoMountEnvironment.parseLoaded("2 0 0 0 BAD(1.0)") == nil)
  let unavailable = DiskEventMonitor(onEvent: { _ in }, baselineProvider: { nil })
  precondition(!unavailable.start(), "基线读取失败不能启动批准")
  let restarted = DiskEventMonitor(onEvent: { _ in }, baselineProvider: { [] })
  precondition(restarted.start())
  try? await Task.sleep(for: .milliseconds(200))
  restarted.stop()
  precondition(restarted.start())
  try? await Task.sleep(for: .milliseconds(600))
  precondition(!restarted.isReady, "上一轮ready计时器影响新会话")
  try? await Task.sleep(for: .milliseconds(200))
  precondition(restarted.isReady)
  restarted.stop()
  precondition(DiskEventMonitor.usbIdentity(serial: "serial",vendor:123,product:456) == "usb:123:456:serial")
  precondition(DiskEventMonitor.usbIdentity(serial: nil,vendor:123,product:456) == nil)
  precondition(DiskEventMonitor.usbIdentity(serial: "serial",vendor:nil,product:456) == nil)
  precondition(DiskEventMonitor.usbIdentity(serial: "serial",vendor:123,product:nil) == nil)
  precondition(DiskEventMonitor.usbIdentity(serial: "x\ny",vendor:123,product:456) == nil)
  precondition(DiskEventMonitor.approvalSnapshot(disk,cached:nil) == nil, "批准回调不扫描缺失缓存")
  precondition(DiskEventMonitor.approvalSnapshot(disk,cached:disk)?.deviceGUID == "g")
  let replaced = DiskEventSnapshot(bsdName:"disk99",mediaID:101,volumeUUID:"v",mediaSize:4096,deviceGUID:nil,isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS")
  precondition(DiskEventMonitor.approvalSnapshot(replaced,cached:disk) == nil,"旧BSD缓存不能补充新介质")
  var offGate = DiskApprovalGate()
  offGate.ready = true
  offGate.observed[99] = disk
  precondition(!offGate.intercept(disk))
  offGate.suppressCurrentlyObserved()
  offGate.rules = [rule]
  precondition(!offGate.intercept(disk), "关闭期间已接入的盘不应追溯拦截")
  offGate.removed(99)
  let reinserted = DiskEventSnapshot(bsdName:"disk99",mediaID:102,volumeUUID:"v",mediaSize:4096,deviceGUID:"g",isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS")
  precondition(offGate.intercept(reinserted), "新接入可应用已保存政策")
  var targeted = DiskApprovalGate()
  targeted.rules = [rule]
  targeted.ready = true
  targeted.authorizationEpoch = 42
  targeted.suppress(mediaID:100)
  precondition(targeted.intercept(disk), "逐盘抑制不能扩大到其他盘")
  precondition(targeted.authorizationEpoch == 42,"一次拦截必须保留所用规则版本")
  targeted.removed(99)
  targeted.suppress(mediaID:99)
  precondition(!targeted.intercept(disk),"当前盘逐盘抑制应持续到移除")
  targeted.removed(99)
  precondition(targeted.intercept(disk),"移除后允许新接入")
  print("原生事件策略通过：启动、基线、一次拦截、移除和竞争分类。")
 }
}
