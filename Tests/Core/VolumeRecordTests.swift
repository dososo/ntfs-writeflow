import Foundation

@main enum VolumeRecordTests {
    static func main() {
        var base: [String: Any] = [
            "DeviceIdentifier": "disk7s1", "ParentWholeDisk": "disk7", "VolumeName": "测试磁盘",
            "VolumeUUID": "测试卷标识", "FilesystemType": "ntfs", "MountPoint": "/Volumes/测试磁盘",
            "Internal": false, "Ejectable": true, "WholeDisk": false,
            "WritableVolume": true, "WritableMedia": true, "TotalSize": 1_000_000,
            "DeviceTreePath": "测试设备路径"
        ]
        func record(_ changes: [String: Any] = [:], mediaID: UInt64? = 101, wholeID: UInt64? = 100) -> VolumeRecord {
            VolumeRecord(info: base.merging(changes, uniquingKeysWith: { _, new in new }),
                         mediaRegistryID: mediaID, wholeMediaRegistryID: wholeID)!
        }
        let ntfs = record()
        check(ntfs.isNTFS && ntfs.access == .readWrite, "NTFS 可写状态")
        check(record(["WritableVolume": false]).access == .readOnly, "卷只读优先于可写介质")
        check(record(["WritableMedia": false]).access == .readOnly, "介质只读优先于卷可写")
        check(record(["MountPoint": ""]).access == .unmounted, "未挂载不显示可写")
        let apfs = record(["FilesystemType": "apfs", "VolumeName": "普通磁盘"])
        check(VolumeRecord.visible([ntfs, apfs], includeOtherVolumes: false) == [ntfs], "默认仅显示 NTFS")
        check(VolumeRecord.visible([], includeOtherVolumes: true).isEmpty, "空列表不造示例盘")
        check(VolumeRecord.visible([ntfs, apfs], includeOtherVolumes: true).count == 2, "显示其他文件系统")
        check(record(["Internal": true]).isProtected, "内部卷保护")
        check(record(["MountPoint": "/"]).isProtected, "根目录保护")
        check(record(["MountPoint": "/System/Volumes/Data"]).isProtected, "系统分卷保护")
        check(record(["VolumeUUID": ""]).canOfferEject, "已有稳定介质身份时不依赖卷UUID")
        check(!ntfs.matchesIdentity(of: record(["VolumeUUID": "替换后的卷"])), "设备编号复用不能冒充原卷")
        check(!ntfs.matchesIdentity(of: record(["TotalSize": 2_000_000])), "容量变化拒绝旧身份")
        check(!ntfs.matchesIdentity(of: record(["DeviceTreePath": "另一设备路径"])), "物理路径变化拒绝旧身份")
        let whole = record(["DeviceIdentifier": "disk7", "WholeDisk": true, "MountPoint": ""], mediaID: 100)
        check(EjectProtection.refusal(expected: ntfs, current: ntfs, wholeDisk: whole, relatedVolumes: [ntfs]) == nil, "完整外部身份可请求弹出")
        check(EjectProtection.refusal(expected: ntfs, current: nil, wholeDisk: whole, relatedVolumes: []) != nil, "设备移除拒绝弹出")
        check(EjectProtection.refusal(expected: ntfs, current: ntfs, wholeDisk: nil, relatedVolumes: []) != nil, "整盘信息缺失拒绝弹出")
        check(EjectProtection.refusal(expected: ntfs, current: ntfs, wholeDisk: whole,
                                     relatedVolumes: [record(["MountPoint": "/System/Volumes/其他"])]) != nil, "受保护兄弟卷阻止整盘弹出")
        check(!record(mediaID: nil).canOfferEject, "未绑定 IOMedia 的卷不允许弹出")
        check(!ntfs.matchesIdentity(of: record(mediaID: 201, wholeID: 200)), "同编号同卷标识的新介质不等于原对象")
        check(EjectProtection.boundIdentityMatches(expected: ntfs, mediaRegistryID: 101,
                  wholeMediaRegistryID: 100, volumeUUID: "测试卷标识", deviceID: "disk7s1",
                  wholeDiskID: "disk7", totalBytes: 1_000_000), "保留对象实际身份一致")
        check(!EjectProtection.boundIdentityMatches(expected: ntfs, mediaRegistryID: 201,
                  wholeMediaRegistryID: 200, volumeUUID: "测试卷标识", deviceID: "disk7s1",
                  wholeDiskID: "disk7", totalBytes: 1_000_000), "BSD 编号与 UUID 相同也拒绝替换的 IOMedia")
        check(!EjectProtection.boundIdentityMatches(expected: ntfs, mediaRegistryID: 101,
                  wholeMediaRegistryID: 200, volumeUUID: "测试卷标识", deviceID: "disk7s1",
                  wholeDiskID: "disk7", totalBytes: 1_000_000), "整盘绑定变化拒绝操作")
        check(EjectVerification.unconfirmedReason(expected: ntfs, records: [], unreadableCount: 1, receipt: .mediaRemoved(wholeMediaRegistryID: ntfs.wholeMediaRegistryID!)) != nil,
              "读取失败造成的缺席不能确认弹出")
        check(EjectVerification.unconfirmedReason(expected: ntfs, records: [], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: ntfs.wholeMediaRegistryID!)) == nil,
              "只有完整清单确认缺席才能报告完成")
        check(EjectVerification.unconfirmedReason(expected: ntfs,
                  records: [record(["VolumeUUID": "替换卷"], mediaID: 201, wholeID: 200)], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: ntfs.wholeMediaRegistryID!)) != nil,
              "同位置出现新盘不能提示可以断开")
        check(EjectVerification.unconfirmedReason(expected: ntfs,
                  records: [record(["DeviceIdentifier": "disk8s1", "ParentWholeDisk": "disk8"])], unreadableCount: 0, receipt: .mediaRemoved(wholeMediaRegistryID: ntfs.wholeMediaRegistryID!)) != nil,
              "同一保留介质仍在清单不能确认弹出")
        base.removeValue(forKey: "Internal")
        check(record().isProtected, "未知设备位置默认保护")
        base.removeValue(forKey: "WritableVolume")
        check(record().access == .unknown, "仅可写介质不能推断卷可写")
        check(!VolumeRecord.validDeviceID("disk7;echo 测试"), "拒绝不合法设备标识")
        check(VolumeRecord.validDeviceID("disk3s1s1"), "接受系统快照设备标识")
        check(VolumeRecord(info: [:]) == nil, "无效系统响应不产生卷")
        print("通过：32 项卷状态、保留对象身份与弹出后置检查；未执行任何磁盘修改。")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("失败：\(name)") }
    }
}
