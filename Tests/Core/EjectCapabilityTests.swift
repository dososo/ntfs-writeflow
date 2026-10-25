import Foundation

// 仅构造记录并调用生产策略，不枚举设备、不请求卸载或弹出。
@main enum EjectCapabilityTests {
    static func main() {
        let base: [String: Any] = [
            "DeviceIdentifier": "disk9999s1", "ParentWholeDisk": "disk9999",
            "VolumeUUID": "原始卷身份", "FilesystemType": "ufsd_ntfs",
            "MountPoint": "/Volumes/测试外接卷", "Internal": false,
            "Ejectable": true, "WholeDisk": false,
            "TotalSize": 1_000_000, "IOKitSize": 1_000_000,
            "DeviceTreePath": "仅用于构造记录的设备路径"
        ]
        func record(_ changes: [String: Any] = [:], mediaID: UInt64? = 999_991,
                    wholeID: UInt64? = 999_990, mounted: MountedFileSystem? = nil) -> VolumeRecord {
            VolumeRecord(info: base.merging(changes, uniquingKeysWith: { _, new in new }),
                         mediaRegistryID: mediaID, wholeMediaRegistryID: wholeID,
                         mountedFileSystem: mounted)!
        }
        let external = record()
        let whole = record(["DeviceIdentifier": "disk9999", "WholeDisk": true,
                            "MountPoint": "", "VolumeUUID": ""], mediaID: 999_990)
        let managedPath = "/private/var/db/com.blteam.ntfsworkbench.mounts/501/11111111-1111-1111-1111-111111111111/volume"
        let mounted = MountedFileSystem(type: "blntfs", source: "/dev/disk9999s1",
            mountPoint: managedPath, identity: "构造的挂载身份", ownerID: 0, isReadOnly: false)
        let managed = record(["MountPoint": managedPath], mounted: mounted)
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, "失败：\(name)")
            checks += 1
        }
        func refusal(_ expected: VolumeRecord = external, current: VolumeRecord? = nil,
                     parent: VolumeRecord? = nil, siblings: [VolumeRecord] = []) -> String? {
            EjectProtection.refusal(expected: expected, current: current ?? expected,
                wholeDisk: parent ?? whole, relatedVolumes: siblings)
        }

        check(AppCapabilities.directEjectEnabled, "已验证生产弹出入口已开放")
        check(external.canOfferEject, "外部其他驱动NTFS卷可请求正常整盘弹出")
        check(!record(["FilesystemType": "apfs"]).canOfferEject, "其他文件系统仅查看，不展示无法执行的弹出入口")
        check(record(["MountPoint": ""]).canOfferEject, "已卸载外部介质仍可弹出")
        check(record(["VolumeUUID": ""]).canOfferEject, "稳定介质身份充分时不依赖卷UUID")
        check(managed.canOfferEject, "本应用受管挂载不因专用目录而失去弹出入口")
        check(!record(["Internal": true]).canOfferEject, "内部磁盘禁止弹出")
        check(!record(["Internal": NSNull()]).canOfferEject, "位置未知禁止弹出")
        check(!record(["Ejectable": false]).canOfferEject, "系统报告不可弹出时禁止")
        check(!record(mediaID: nil).canOfferEject, "缺少分卷介质身份禁止")
        check(!record(wholeID: nil).canOfferEject, "缺少整盘介质身份禁止")
        check(!record(mediaID: 0).canOfferEject, "零分卷介质身份禁止")
        check(!record(wholeID: 0).canOfferEject, "零整盘介质身份禁止")
        check(!record(["IOKitSize": 0]).canOfferEject, "容量未知禁止")
        check(!record(["ParentWholeDisk": "disk9999s1"]).canOfferEject, "分区编号不能充当整盘")
        check(!record(["ParentWholeDisk": "disk9999;echo test"]).canOfferEject, "非法整盘编号禁止")
        check(!record(["MountPoint": "/"]).canOfferEject, "根目录保护")
        check(!record(["MountPoint": "/System/Volumes/Data"]).canOfferEject, "系统路径保护")
        check(!record(["MountPoint": managedPath]).canOfferEject, "仅路径相似不能冒充受管挂载")
        let forgedSource = MountedFileSystem(type: "blntfs", source: "/dev/disk9998s1",
            mountPoint: managedPath, identity: "构造的挂载身份", ownerID: 0, isReadOnly: false)
        check(!record(["MountPoint": managedPath], mounted: forgedSource).canOfferEject,
              "其他设备挂载来源不能冒充本卷")
        let forgedPath = MountedFileSystem(type: "blntfs", source: "/dev/disk9999s1",
            mountPoint: managedPath + "/子目录", identity: "构造的挂载身份", ownerID: 0, isReadOnly: false)
        check(!record(["MountPoint": managedPath], mounted: forgedPath).canOfferEject,
              "内核挂载根目录不符禁止")
        let systemMounted = MountedFileSystem(type: "blntfs", source: "/dev/disk9999s1",
            mountPoint: "/System/Volumes/伪装", identity: "构造的挂载身份", ownerID: 0, isReadOnly: false)
        check(!record(["MountPoint": "/System/Volumes/伪装"], mounted: systemMounted).canOfferEject,
              "即使内核来源为blntfs也不能放行系统挂载路径")
        let temporaryPath = "/private/tmp/ntfs-writeflow-501/11111111-1111-1111-1111-111111111111"
        let temporaryMounted = MountedFileSystem(type: "blntfs", source: "/dev/disk9999s1",
            mountPoint: temporaryPath, identity: "构造的挂载身份", ownerID: 501, isReadOnly: false)
        check(record(["MountPoint": temporaryPath], mounted: temporaryMounted).canOfferEject,
              "用户上下文的本应用镜像挂载也提供弹出入口")
        check(refusal() == nil, "完整外部整盘身份通过前置策略")
        check(refusal(managed, siblings: [managed]) == nil, "本应用挂载在同盘校验中允许正常卸载")
        let wholeMounted = MountedFileSystem(type: "blntfs", source: "/dev/disk9999",
            mountPoint: managedPath, identity: "未分区整盘挂载实例", ownerID: 0, isReadOnly: false)
        let unpartitioned = record(["DeviceIdentifier": "disk9999", "WholeDisk": true,
                                    "MountPoint": managedPath], mediaID: 999_990, mounted: wholeMounted)
        check(EjectProtection.refusal(expected: unpartitioned, current: unpartitioned,
                wholeDisk: unpartitioned, relatedVolumes: [unpartitioned]) == nil,
              "无分区NTFS整盘已由本应用挂载时仍允许弹出")
        let internalWhole = record(["DeviceIdentifier": "disk9999", "WholeDisk": true,
                                    "MountPoint": managedPath, "Internal": true], mediaID: 999_990, mounted: wholeMounted)
        check(EjectProtection.refusal(expected: unpartitioned, current: unpartitioned,
                wholeDisk: internalWhole, relatedVolumes: [unpartitioned]) != nil,
              "整盘内部属性不因blntfs挂载放行")
        let systemWholeMount = MountedFileSystem(type: "blntfs", source: "/dev/disk9999",
            mountPoint: "/System/Volumes/伪整盘", identity: "伪系统整盘实例", ownerID: 0, isReadOnly: false)
        let systemWhole = record(["DeviceIdentifier": "disk9999", "WholeDisk": true,
                                  "MountPoint": "/System/Volumes/伪整盘"], mediaID: 999_990, mounted: systemWholeMount)
        check(EjectProtection.refusal(expected: unpartitioned, current: unpartitioned,
                wholeDisk: systemWhole, relatedVolumes: [unpartitioned]) != nil,
              "整盘任意系统路径仍拒绝，不因实际blntfs来源放行")
        check(refusal(current: record(["VolumeUUID": "挂载驱动返回不同UUID"])) == nil,
              "同一介质不因驱动UUID表示改变被误判")
        check(refusal(current: record(mediaID: 888_881, wholeID: 888_880)) != nil,
              "相同BSD和UUID但介质对象替换拒绝")
        check(refusal(current: record(["IOKitSize": 2_000_000])) != nil, "实际介质容量改变拒绝")
        check(refusal(current: record(["DeviceTreePath": "另一个路径"])) != nil, "设备路径改变拒绝")
        let wrongWhole = record(["DeviceIdentifier": "disk9999", "WholeDisk": true, "MountPoint": ""],
                                mediaID: 888_880, wholeID: 888_880)
        check(refusal(parent: wrongWhole) != nil, "同编号整盘IOMedia替换拒绝")
        check(refusal(parent: record(["DeviceIdentifier": "disk9999", "WholeDisk": false,
                                     "MountPoint": ""], mediaID: 999_990)) != nil,
              "父记录不是整盘时拒绝")
        let protectedSibling = record(["DeviceIdentifier": "disk9999s2", "MountPoint": "/System/Volumes/保护卷"], mediaID: 999_992)
        check(refusal(siblings: [external, protectedSibling]) != nil, "同盘受保护分卷阻止整盘弹出")
        let otherProtected = record(["DeviceIdentifier": "disk8888s2", "ParentWholeDisk": "disk8888",
                                     "MountPoint": "/System/Volumes/其他盘"], mediaID: 888_882, wholeID: 888_880)
        check(refusal(siblings: [external, otherProtected]) == nil, "无关磁盘不参与本盘弹出策略")
        check(EjectProtection.refusal(expected: external, current: nil, wholeDisk: whole, relatedVolumes: []) != nil,
              "目标缺席拒绝提交")
        check(EjectProtection.refusal(expected: external, current: external, wholeDisk: nil, relatedVolumes: []) != nil,
              "整盘状态缺失拒绝提交")
        check(EjectVerification.unconfirmedReason(expected: external, records: [], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: external.wholeMediaRegistryID!)) == nil,
              "完整清单中原盘消失才确认成功")
        check(EjectVerification.unconfirmedReason(expected: external, records: [], unreadableCount: 1, receipt: .mediaRemoved(wholeMediaRegistryID: external.wholeMediaRegistryID!)) != nil,
              "读取错误导致的缺席不算成功")
        check(EjectVerification.unconfirmedReason(expected: external, records: [whole], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: external.wholeMediaRegistryID!)) != nil,
              "原整盘仍存在不算成功")
        check(EjectVerification.unconfirmedReason(expected: external, records: [record(mediaID: 888_881, wholeID: 888_880)], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: external.wholeMediaRegistryID!)) != nil,
              "设备位置已出现另一盘时不提示可拔盘")
        let unmounted = record(["MountPoint": ""])
        let fixedReceipt = EjectReceipt.fixedMediaConnected(mediaRegistryID: 999_991,
            wholeMediaRegistryID: 999_990, mediaByteCount: 1_000_000, wholeMediaByteCount: 1_000_000)
        func fixedCheck(_ records: [VolumeRecord], receipt: EjectReceipt? = fixedReceipt, unreadable: Int = 0) -> String? {
            EjectVerification.unconfirmedReason(expected: external, records: records,
                unreadableCount: unreadable, receipt: receipt)
        }
        check(fixedCheck([unmounted, whole]) == nil, "固定外部盘成功回执允许原对象保留且无挂载")
        check(fixedCheck([unmounted, whole], receipt: nil) != nil, "普通未挂载无成功回执绝不算弹出")
        check(fixedCheck([], receipt: nil) != nil, "普通缺席无成功回执也不算弹出")
        check(fixedCheck([external, whole]) != nil, "成功回执后重新挂载必须拒绝")
        check(fixedCheck([record(["MountPoint": ""], mediaID: 888_881), whole]) != nil, "原分卷身份变化拒绝")
        check(fixedCheck([unmounted, record(["DeviceIdentifier": "disk9999", "WholeDisk": true, "MountPoint": ""], mediaID: 888_880)]) != nil, "整盘身份变化拒绝")
        check(fixedCheck([record(["MountPoint": "", "IOKitSize": 2_000_000]), whole]) != nil, "原容量变化拒绝")
        check(fixedCheck([unmounted]) != nil, "固定回执必须能确认完整整盘记录")
        check(fixedCheck([unmounted, whole], unreadable: 1) != nil, "读取不完整拒绝固定回执确认")
        check(fixedCheck([unmounted, whole], receipt: .mediaRemoved(wholeMediaRegistryID: 999_990)) != nil, "移除类型回执不能用于仍连接设备")
        var session = EjectedMediaSession()
        check(!session.contains(unmounted), "未取得回执不抑制挂载入口")
        session.remember(fixedReceipt)
        check(session.contains(unmounted), "成功回执抑制相同插入实例")
        session.reconcile(records: [unmounted, whole], unreadableCount: 0)
        check(session.contains(unmounted), "普通刷新保留已成功实例")
        check(!session.contains(record(["MountPoint": ""], mediaID: 888_881, wholeID: 888_880)), "重插新身份不被旧回执抑制")
        check(session.reconcile(records: [external, whole], unreadableCount: 0) && !session.contains(external), "其他程序重新挂载撤销安全状态")
        session.remember(fixedReceipt)
        check(session.reconcile(records: [], unreadableCount: 0) && !session.contains(unmounted), "原插入实例退出清除会话缓存")
        print("通过：\(checks) 项生产弹出策略及后置核对；未读取或修改任何设备。")
    }
}
