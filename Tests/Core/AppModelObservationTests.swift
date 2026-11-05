import AppKit
import Combine
import Foundation

@main enum AppModelObservationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let defaults = UserDefaults(suiteName: "writeflow.observation.\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        func published(_ message: String, _ mutation: () -> Void) {
            let before = changes
            mutation()
            check(changes > before, message)
        }
        let volume = VolumeRecord(info: ["DeviceIdentifier": "disk910s1", "VolumeName": "观察测试", "FilesystemType": "ntfs",
            "ParentWholeDisk": "disk910", "Internal": false, "WholeDisk": false, "WritableMedia": true,
            "IOKitSize": 4096], mediaRegistryID: 9101, wholeMediaRegistryID: 9100)!
        var deliveredRecords = 0
        let records = model.$records.dropFirst().sink { deliveredRecords = $0.count }
        published("卷清单变更必须发布") { model.records = [volume] }
        check(deliveredRecords == 1 && model.volumes.count == 1 && model.ntfsVolumes.count == 1,
              "真实Combine收到清单，派生可见卷及NTFS数量随之更新")
        published("选中状态必须发布") { model.selectedID = volume.id }
        check(model.selectedVolume?.id == volume.id, "派生详情随选中卷更新")
        published("刷新状态必须发布") { model.isRefreshing = true }
        check(model.isBusy, "派生忙碌状态反映刷新")
        published("刷新结束必须发布") { model.isRefreshing = false }
        check(!model.isBusy, "派生忙碌状态恢复")
        published("自动事务状态必须发布") { model.autoIsOperating = true }
        check(model.isBusy, "派生忙碌状态反映自动事务")
        model.autoIsOperating = false
        published("自动状态提示必须发布") { model.autoStatus = "测试提示" }
        published("登录状态必须发布") { model.loginState = .enabled }
        check(model.loginEnabled, "派生登录开关来自已发布状态")
        published("会话结构体原位变更必须发布") { model.autoSession.setSleeping(true) }
        check(model.automaticSessionStatus.contains("睡眠"), "会话派生提示随结构体变更更新")
        published("扩展诊断必须发布") {
            model.extensionDiagnostic = ExtensionDiagnostic(title: "测试", detail: "", isEnabled: true)
        }
        published("操作提示必须发布") { model.operationMessage = "已完成" }
        published("错误提示必须发布") { model.errorMessage = "测试错误" }
        let beforeIgnored = changes
        model.autoPolicyEpoch &+= 1
        model.verificationSequence += 1
        check(changes == beforeIgnored, "原忽略的监控代次和诊断计数不发布界面更新")
        withExtendedLifetime([observation, records]) {}
        print("通过：\(checks)项真实AppModel Combine订阅、派生状态及忽略字段检查；未启动监控或操作磁盘。")
    }
}
