import Foundation

@main enum MountStateTests {
    static func main() {
        let base: [String: Any] = [
            "DeviceIdentifier": "disk7s1", "ParentWholeDisk": "disk7", "VolumeUUID": "原卷标识",
            "FilesystemType": "ufsd_NTFS", "MountPoint": "/private/tmp/ntfs-writeflow-501/测试卷",
            "Internal": false, "TotalSize": 1_000_000, "WritableMedia": true, "WritableVolume": true
        ]
        let live = MountedFileSystem(type: "blntfs", source: "/dev/disk7s1",
            mountPoint: "/private/tmp/ntfs-writeflow-501/测试卷", identity: "11:22", ownerID: 501, isReadOnly: true)
        func record(_ changes: [String: Any] = [:], state: MountedFileSystem? = live,
                    mediaID: UInt64? = 101) -> VolumeRecord {
            VolumeRecord(info: base.merging(changes, uniquingKeysWith: { _, new in new }),
                mediaRegistryID: mediaID, wholeMediaRegistryID: 100, mountedFileSystem: state)!
        }
        let own = record()
        check(own.isMountedByWriteFlow, "媒体类型报告为 Paragon 时仍从内核识别实际 blntfs")
        check(own.access == .readOnly, "内核只读标志覆盖 diskutil 可写报告")
        check(own.canOfferUnmount, "自有临时目录挂载可提供卸载")
        check(!own.canOfferMount, "已挂载卷禁止再次挂载")
        check(!record(state: nil).canOfferUnmount, "缺少内核挂载证据拒绝卸载")
        check(!record(["Internal": true]).canOfferUnmount, "内部卷拒绝卸载")
        check(!record(mediaID: nil).canOfferUnmount, "缺少介质身份拒绝卸载")
        check(record(["VolumeUUID": ""]).canOfferUnmount, "无卷UUID时仍可由介质与真实挂载实例确认卸载目标")
        let other = MountedFileSystem(type: "ufsd_NTFS", source: live.source,
            mountPoint: live.mountPoint, identity: live.identity, ownerID: 501, isReadOnly: false)
        check(!record(state: other).canOfferUnmount, "不接管其他驱动挂载")
        let wrongSource = MountedFileSystem(type: "blntfs", source: "/dev/disk8s1",
            mountPoint: live.mountPoint, identity: live.identity, ownerID: 501, isReadOnly: false)
        check(!record(state: wrongSource).canOfferUnmount, "不同来源设备拒绝卸载")
        let wrongPath = MountedFileSystem(type: "blntfs", source: live.source,
            mountPoint: "/", identity: live.identity, ownerID: 501, isReadOnly: false)
        check(!record(state: wrongPath).canOfferUnmount, "父目录statfs不能冒充挂载根目录")
        let unmounted = record(["MountPoint": ""], state: nil)
        check(unmounted.canOfferMount, "外部未挂载NTFS可请求挂载")
        check(!record(["MountPoint": "", "Internal": true], state: nil).canOfferMount, "内部盘不可挂载")
        check(!record(["MountPoint": "", "FilesystemType": "apfs"], state: nil).canOfferMount, "不挂载其他文件系统")
        check(!record(["MountPoint": ""], state: nil, mediaID: nil).canOfferMount, "缺少稳定介质对象拒绝挂载")
        check(own.matchesMediaIdentity(of: record(["VolumeUUID": "FSKit新卷标识"])), "驱动更换卷UUID不改变已绑定介质身份")
        check(!own.matchesMediaIdentity(of: record(mediaID: 202)), "相同设备编号与卷UUID不接受新介质")
        check(!own.matchesMediaIdentity(of: record(["TotalSize": 2_000_000])), "容量变化拒绝旧介质身份")
        let beforeMount = record(["MountPoint": "", "TotalSize": 1_000_000, "IOKitSize": 1_000_000], state: nil)
        let afterMount = record(["TotalSize": 983_040, "IOKitSize": 1_000_000, "VolumeUUID": "FSKit新卷标识"])
        check(beforeMount.matchesMediaIdentity(of: afterMount), "挂载后展示容量与UUID变化不误判稳定介质")
        check(afterMount.totalBytes == 983_040 && afterMount.mediaByteCount == 1_000_000, "展示容量和介质容量分别保存")
        check(!beforeMount.matchesMediaIdentity(of: record(["IOKitSize": 2_000_000])), "实际介质容量变化仍拒绝")
        check(record(["MountPoint": "", "VolumeUUID": ""], state: nil).canOfferMount, "无卷UUID但有稳定介质对象可进入挂载前校验")
        check(!record(["MountPoint": "", "TotalSize": 0], state: nil).canOfferMount, "无法确认介质容量时不挂载")
        print("通过：23 项实际挂载状态和操作保护；未执行挂载或卸载。")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("失败：\(name)") }
    }
}
