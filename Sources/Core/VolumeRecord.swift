import Foundation

enum AppCapabilities {
    // 整盘由已核验并持续持有的原始设备句柄绑定；只执行正常卸载和弹出。
    static let directEjectEnabled = true
    // 扩展端介质身份正反验证已通过；挂载仍逐次核对系统实际状态。
    static let directMountEnabled = true
}

struct MountedFileSystem: Equatable, Sendable {
    let type: String
    let source: String
    let mountPoint: String
    let identity: String
    let ownerID: UInt32
    let isReadOnly: Bool
}

enum VolumeAccess: String, Sendable {
    case unmounted = "未挂载"
    case readOnly = "只读"
    case readWrite = "可读写"
    case unknown = "访问状态未知"
}

struct VolumeRecord: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fileSystem: String
    let fileSystemName: String
    let volumeUUID: String?
    let wholeDiskID: String
    let deviceTreePath: String?
    let mountPoint: String?
    let isInternal: Bool?
    let isEjectable: Bool
    let isWholeDisk: Bool
    let isNTFS: Bool
    let writableVolume: Bool?
    let writableMedia: Bool?
    let totalBytes: Int64
    let mediaByteCount: Int64
    let freeBytes: Int64?
    let mediaRegistryID: UInt64?
    let wholeMediaRegistryID: UInt64?
    let mountedFileSystem: MountedFileSystem?

    init?(info: [String: Any], mediaRegistryID: UInt64? = nil, wholeMediaRegistryID: UInt64? = nil,
          mountedFileSystem: MountedFileSystem? = nil) {
        guard let identifier = info["DeviceIdentifier"] as? String,
              Self.validDeviceID(identifier) else { return nil }
        id = identifier
        name = Self.nonempty(info["VolumeName"] as? String) ?? identifier
        fileSystem = Self.nonempty(info["FilesystemType"] as? String) ?? ""
        fileSystemName = Self.nonempty(info["FilesystemName"] as? String) ?? fileSystem
        volumeUUID = Self.nonempty(info["VolumeUUID"] as? String)
        wholeDiskID = info["ParentWholeDisk"] as? String ?? identifier
        deviceTreePath = Self.nonempty(info["DeviceTreePath"] as? String)
        mountPoint = Self.nonempty(info["MountPoint"] as? String)
        isInternal = info["Internal"] as? Bool
        isEjectable = info["Ejectable"] as? Bool ?? false
        isWholeDisk = info["WholeDisk"] as? Bool ?? false
        let declaredType = fileSystem.lowercased()
        isNTFS = ["ntfs", "ufsd_ntfs", "blntfs"].contains(declaredType)
            || fileSystemName.lowercased().contains("ntfs")
            || (info["Content"] as? String) == "Windows_NTFS"
        writableVolume = info["WritableVolume"] as? Bool ?? info["Writable"] as? Bool
        writableMedia = info["WritableMedia"] as? Bool
        totalBytes = (info["TotalSize"] as? NSNumber)?.int64Value
            ?? (info["Size"] as? NSNumber)?.int64Value ?? 0
        mediaByteCount = (info["IOKitSize"] as? NSNumber)?.int64Value ?? totalBytes
        freeBytes = (info["APFSContainerFree"] as? NSNumber)?.int64Value
            ?? (info["VolumeFreeSpace"] as? NSNumber)?.int64Value
            ?? (info["FreeSpace"] as? NSNumber)?.int64Value
        self.mediaRegistryID = mediaRegistryID
        self.wholeMediaRegistryID = wholeMediaRegistryID
        self.mountedFileSystem = mountedFileSystem
    }

    var isVolume: Bool { !fileSystem.isEmpty || isNTFS || mountPoint != nil }

    var access: VolumeAccess {
        guard mountPoint != nil else { return .unmounted }
        if let mountedFileSystem { return mountedFileSystem.isReadOnly ? .readOnly : .readWrite }
        if writableVolume == false || writableMedia == false { return .readOnly }
        if writableVolume == true { return .readWrite }
        return .unknown
    }

    var isProtected: Bool {
        guard isInternal == false else { return true }
        if let path = mountPoint, !path.hasPrefix("/Volumes/") { return true }
        return false
    }

    var canOfferMount: Bool {
        isInternal == false && isNTFS && mountPoint == nil && mediaByteCount > 0
            && mediaRegistryID != nil && wholeMediaRegistryID != nil
    }

    var isMountedByWriteFlow: Bool {
        mountedFileSystem?.type == "blntfs" && mountedFileSystem?.source == "/dev/\(id)"
            && mountedFileSystem?.mountPoint == mountPoint
    }

    var canOfferUnmount: Bool {
        isInternal == false && isMountedByWriteFlow && mediaRegistryID != nil
            && wholeMediaRegistryID != nil
    }

    func matchesMediaIdentity(of other: VolumeRecord) -> Bool {
        guard mediaRegistryID != nil, wholeMediaRegistryID != nil else { return false }
        return id == other.id && wholeDiskID == other.wholeDiskID && mediaByteCount == other.mediaByteCount
            && deviceTreePath == other.deviceTreePath && mediaRegistryID == other.mediaRegistryID
            && wholeMediaRegistryID == other.wholeMediaRegistryID
    }

    var isProtectedForEject: Bool {
        guard isProtected else { return false }
        guard canOfferUnmount, let path = mountPoint else { return true }
        // 只为本应用已核验的专用挂载位置放行，不能把任意 blntfs 系统路径视作外接卷。
        return path.range(of: #"^/private/(tmp/ntfs-writeflow-[0-9]+/[A-F0-9-]{36}|var/db/com\.blteam\.ntfsworkbench\.mounts/[0-9]+/[A-F0-9-]{36}/volume)$"#,
                          options: .regularExpression) == nil
    }

    var canOfferEject: Bool {
        isNTFS && isInternal == false && !isProtectedForEject && isEjectable && mediaByteCount > 0
            && (mediaRegistryID ?? 0) > 0 && (wholeMediaRegistryID ?? 0) > 0
            && wholeDiskID.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
    }

    func matchesIdentity(of other: VolumeRecord) -> Bool {
        guard let uuid = volumeUUID, let otherUUID = other.volumeUUID else { return false }
        return id == other.id && uuid == otherUUID && wholeDiskID == other.wholeDiskID
            && mediaByteCount == other.mediaByteCount && deviceTreePath == other.deviceTreePath
            && mediaRegistryID == other.mediaRegistryID && wholeMediaRegistryID == other.wholeMediaRegistryID
    }

    static func visible(_ records: [VolumeRecord], includeOtherVolumes: Bool) -> [VolumeRecord] {
        records.filter { $0.isVolume && (includeOtherVolumes || $0.isNTFS) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func validDeviceID(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

enum EjectProtection {
    static func boundIdentityMatches(expected: VolumeRecord, mediaRegistryID: UInt64,
                                     wholeMediaRegistryID: UInt64, volumeUUID: String?,
                                     deviceID: String, wholeDiskID: String, totalBytes: Int64) -> Bool {
        expected.mediaRegistryID == mediaRegistryID && expected.wholeMediaRegistryID == wholeMediaRegistryID
            && expected.volumeUUID?.lowercased() == volumeUUID?.lowercased()
            && expected.id == deviceID && expected.wholeDiskID == wholeDiskID && expected.mediaByteCount == totalBytes
    }

    static func refusal(expected: VolumeRecord, current: VolumeRecord?,
                        wholeDisk: VolumeRecord?, relatedVolumes: [VolumeRecord]) -> String? {
        guard let current, expected.matchesMediaIdentity(of: current) else {
            return "磁盘身份已变化或设备已移除，请刷新后重新选择。"
        }
        guard current.canOfferEject else { return "此卷不允许从本应用弹出。" }
        guard let wholeDisk, wholeDisk.id == current.wholeDiskID,
              wholeDisk.isWholeDisk, !wholeDisk.isProtectedForEject, wholeDisk.isEjectable,
              wholeDisk.mediaRegistryID == expected.wholeMediaRegistryID,
              wholeDisk.wholeMediaRegistryID == expected.wholeMediaRegistryID,
              wholeDisk.mediaByteCount > 0 else {
            return "无法确认整盘可安全弹出，已停止操作。"
        }
        guard !relatedVolumes.contains(where: { $0.wholeDiskID == current.wholeDiskID && $0.isProtectedForEject }) else {
            return "同一磁盘存在受保护分卷，已停止整盘弹出。"
        }
        return nil
    }
}

enum EjectReceipt: Sendable {
    case mediaRemoved(wholeMediaRegistryID: UInt64)
    case fixedMediaConnected(mediaRegistryID: UInt64, wholeMediaRegistryID: UInt64,
                             mediaByteCount: Int64, wholeMediaByteCount: Int64)

    var wholeMediaRegistryID: UInt64 {
        switch self {
        case .mediaRemoved(let id): return id
        case .fixedMediaConnected(_, let id, _, _): return id
        }
    }

    var message: String {
        switch self {
        case .mediaRemoved: return "磁盘已弹出，可以安全断开连接。"
        case .fixedMediaConnected: return "已安全推出，设备仍连接，可以断开。"
        }
    }
}

enum EjectVerification {
    static func unconfirmedReason(expected: VolumeRecord, records: [VolumeRecord], unreadableCount: Int,
                                  receipt: EjectReceipt? = nil) -> String? {
        guard unreadableCount == 0 else { return "部分设备状态读取失败，尚不能确认弹出完成。请勿据此断开磁盘。" }
        guard let receipt, receipt.wholeMediaRegistryID == expected.wholeMediaRegistryID else {
            return "没有原整盘成功弹出的回执，尚不能确认弹出完成。"
        }
        let related = records.filter {
            $0.wholeDiskID == expected.wholeDiskID || $0.id == expected.wholeDiskID
                || $0.mediaRegistryID == expected.mediaRegistryID
                || $0.wholeMediaRegistryID == expected.wholeMediaRegistryID
        }
        switch receipt {
        case .mediaRemoved:
            return related.isEmpty ? nil : "系统仍报告该磁盘或相同设备位置存在，尚不能确认弹出完成。"
        case .fixedMediaConnected(let mediaID, let wholeID, let bytes, let wholeBytes):
            guard mediaID == expected.mediaRegistryID, bytes == expected.mediaByteCount,
                  let current = related.first(where: { $0.id == expected.id }),
                  expected.matchesMediaIdentity(of: current),
                  let whole = related.first(where: { $0.id == expected.wholeDiskID }),
                  whole.isWholeDisk, whole.mediaRegistryID == wholeID,
                  whole.wholeMediaRegistryID == wholeID, whole.mediaByteCount == wholeBytes,
                  related.allSatisfy({ $0.isInternal == false && $0.wholeMediaRegistryID == wholeID
                      && $0.mountPoint == nil && $0.mountedFileSystem == nil }) else {
                return "成功回执后的介质身份或挂载状态已变化，暂勿断开磁盘。"
            }
            return nil
        }
    }
}

// 只记住本会话收到成功回执的插入实例；其他程序重新挂载会撤销该状态。
struct EjectedMediaSession {
    private(set) var wholeMediaIDs: Set<UInt64> = []

    mutating func remember(_ receipt: EjectReceipt) { wholeMediaIDs.insert(receipt.wholeMediaRegistryID) }
    func contains(_ volume: VolumeRecord) -> Bool {
        volume.wholeMediaRegistryID.map { wholeMediaIDs.contains($0) } ?? false
    }
    @discardableResult mutating func reconcile(records: [VolumeRecord], unreadableCount: Int) -> Bool {
        let before = wholeMediaIDs
        let mounted = Set(records.filter { $0.mountPoint != nil || $0.mountedFileSystem != nil }.compactMap(\.wholeMediaRegistryID))
        wholeMediaIDs.subtract(mounted)
        if unreadableCount == 0 { wholeMediaIDs.formIntersection(Set(records.compactMap(\.wholeMediaRegistryID))) }
        return before != wholeMediaIDs
    }
}
