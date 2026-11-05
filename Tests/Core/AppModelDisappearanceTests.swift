import AppKit
import Foundation
import Darwin

@main enum AppModelDisappearanceTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("失败：\(message)"); exit(1) }
            checks += 1
        }
        func volume(_ device: String, media: UInt64, whole: UInt64, parent: String, wholeDisk: Bool) -> VolumeRecord {
            VolumeRecord(info: ["DeviceIdentifier": device, "VolumeName": "同名卷", "FilesystemType": "ntfs",
                                "VolumeUUID": "volume-\(media)", "ParentWholeDisk": parent, "Internal": false,
                                "WholeDisk": wholeDisk, "WritableMedia": true, "IOKitSize": 4096],
                         mediaRegistryID: media, wholeMediaRegistryID: whole)!
        }
        func disappeared(_ volume: VolumeRecord) -> DiskEvent {
            DiskEvent(kind: .disappeared,
                      snapshot: DiskEventSnapshot(bsdName: volume.id, mediaID: volume.mediaRegistryID,
                          volumeUUID: volume.volumeUUID, mediaSize: volume.mediaByteCount, deviceGUID: nil,
                          isInternal: false, volumeKind: "ntfs", mountPath: nil, contentHint: "Windows_NTFS"),
                      isStartup: false)
        }
        let root = volume("disk201", media: 201, whole: 201, parent: "disk201", wholeDisk: true)
        let first = volume("disk201s1", media: 202, whole: 201, parent: "disk201", wholeDisk: false)
        let sibling = volume("disk201s2", media: 203, whole: 201, parent: "disk201", wholeDisk: false)
        let other = volume("disk204", media: 204, whole: 204, parent: "disk204", wholeDisk: true)
        let reusedBSD = volume("disk201", media: 205, whole: 205, parent: "disk201", wholeDisk: true)
        let snapshot = DiskSnapshot(records: [root, first, sibling, other], unreadableCount: 0)
        let defaults = UserDefaults(suiteName: "writeflow.disappearance.\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        let previousRefresh = model.automaticRefresh
        defer { model.automaticRefresh = previousRefresh }
        model.automaticRefresh = true
        model.apply(snapshot)
        model.selectedID = first.id
        model.isRefreshing = true // 模拟旧的磁盘快照已在等待回包。
        await model.processAutoEvent(disappeared(first))
        check(!model.records.contains(where: { $0.mediaRegistryID == 202 }), "分卷消失应立即移除")
        check(Set(model.records.compactMap(\.mediaRegistryID)) == [201, 203, 204], "分卷消失不能误删同盘其他卷或同名卷")
        model.apply(snapshot)
        check(!model.records.contains(where: { $0.mediaRegistryID == 202 }), "旧快照不能复活消失分卷")
        model.selectedID = sibling.id
        await model.processAutoEvent(disappeared(root))
        check(model.records.compactMap(\.mediaRegistryID) == [204], "整盘消失应移除根介质及其子卷")
        check(model.selectedID == other.id, "消失卷不能继续保持选中")
        model.apply(snapshot)
        check(model.records.compactMap(\.mediaRegistryID) == [204], "已在途旧快照不能复活整盘和子卷")
        model.isRefreshing = false
        model.apply(DiskSnapshot(records: [root, first, sibling, other, reusedBSD], unreadableCount: 0))
        check(Set(model.records.compactMap(\.mediaRegistryID)) == [204, 205], "同名或复用BSD名的新registry身份应保留")
        model.stopMonitoring()
        model.apply(snapshot)
        check(model.records.compactMap(\.mediaRegistryID) == [204], "停止监控不能清除防旧快照复活的身份记录")

        let offModel = AppModel(defaults: defaults)
        offModel.automaticRefresh = false
        offModel.apply(snapshot)
        offModel.selectedID = first.id
        await offModel.processAutoEvent(disappeared(root))
        check(Set(offModel.records.compactMap(\.mediaRegistryID)) == [201, 202, 203, 204], "关闭自动刷新时保留列表直到手动刷新")
        check(offModel.selectedID == first.id, "关闭自动刷新时保留当前选择")
        offModel.apply(DiskSnapshot(records: [other], unreadableCount: 0)) // 手动刷新回包。
        check(offModel.records.compactMap(\.mediaRegistryID) == [204], "关闭自动刷新仍允许手动刷新移除消失卷")
        offModel.automaticRefresh = true
        offModel.apply(snapshot)
        check(offModel.records.compactMap(\.mediaRegistryID) == [204], "重新开启后旧快照也不能复活关闭期间消失的身份")
        print("通过：\(checks)项真实AppModel列表消失、旧快照、整盘分卷、身份复用、选择及自动刷新开关检查；仅注入快照和事件，未操作磁盘。")
    }
}
