import Foundation

@main enum InventoryReadOnlyProbe {
    static func main() async throws {
        let snapshot = try await DiskService().snapshot()
        let volumes = VolumeRecord.visible(snapshot.records, includeOtherVolumes: true)
        guard !snapshot.records.isEmpty else { fatalError("系统磁盘清单为空，未获得有效验证。") }
        guard !snapshot.records.contains(where: { $0.isInternal == true && $0.canOfferEject }) else {
            fatalError("内部磁盘被错误标记为可弹出。")
        }
        print("真实只读清单：\(snapshot.records.count) 个设备，\(volumes.count) 个文件系统卷，\(snapshot.unreadableCount) 个读取失败。")
        print("已核对并保留 IOMedia 身份：\(snapshot.records.filter { $0.mediaRegistryID != nil }.count) 个设备。")
        print("默认 NTFS 列表：\(VolumeRecord.visible(snapshot.records, includeOtherVolumes: false).count) 个卷；未执行挂载、写入或弹出。")
    }
}
