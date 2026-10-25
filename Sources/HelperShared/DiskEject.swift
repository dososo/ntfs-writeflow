import Foundation
import Darwin
import DiskArbitration
import IOKit

enum HelperEjectPolicy {
    static func validate(_ request: PrivilegedEjectRequest, userID: UInt32) throws {
        guard userID >= 501, userID != UInt32.max,
              VolumeRecord.validDeviceID(request.deviceID),
              request.wholeDiskID.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              request.deviceID == request.wholeDiskID || request.deviceID.hasPrefix(request.wholeDiskID + "s"),
              request.mediaRegistryID > 0, request.wholeMediaRegistryID > 0,
              request.mediaByteCount > 0, request.wholeMediaByteCount >= request.mediaByteCount else {
            throw HelperFailure(message: "整盘弹出请求的介质身份或容量无效。")
        }
    }

    static func validateMount(_ mount: MountedFileSystem, userID: UInt32) throws {
        guard mount.type != "blntfs" else {
            throw HelperFailure(message: "同盘仍有 NTFS 畅写挂载，请先正常卸载后再弹出。")
        }
        guard mount.mountPoint.hasPrefix("/Volumes/"),
              mount.mountPoint.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              mount.ownerID == 0 || mount.ownerID == userID else {
            throw HelperFailure(message: "同盘存在受保护路径或其他用户的挂载，已停止整盘弹出。")
        }
    }

    static func permitsConnectedFixedMedia(location: String?, ejectable: Bool?, removable: Bool?, openStates: [Bool?]) -> Bool {
        location == "External" && ejectable == false && removable == false
            && !openStates.isEmpty && openStates.allSatisfy { $0 == false }
    }

    static func ejectWithBusyRetry(validate: () throws -> Void, attempt: () -> Int32, wait: () -> Void) throws {
        // 正常卸载完成后仍可能短暂有设备打开引用；保持同一描述符，只重试 EBUSY。
        // 等待总量上限为 30 × 100 毫秒；每次重试均重新核对身份与空挂载清单。
        for index in 0...30 {
            try validate()
            let error = attempt()
            if error == 0 { return }
            guard error == EBUSY, index < 30 else {
                throw HelperFailure(message: "分卷可能已卸载，但整盘未弹出（\(error)）；请关闭占用程序后重试。")
            }
            wait()
        }
    }
}

// 先通过已绑定挂载根的事件描述符正常卸载；原始设备只读授权由前台在卸载后发起。
// 前台取得授权描述符后再次核验原对象，仅对同一描述符弹出，避免 BSD 编号复用及提前打开造成的引用占用。
final class HelperEject {
    private let request: PrivilegedEjectRequest
    private let userID: UInt32
    private let session: DASession
    private let disk: DADisk
    private let wholeDisk: DADisk
    private let media: io_service_t
    private let wholeMedia: io_service_t
    private var wasFixedExternal = false

    init(request: PrivilegedEjectRequest, userID: UInt32) throws {
        try HelperEjectPolicy.validate(request, userID: userID)
        // 原始设备已打开的第二阶段不能再次调用可能探测设备内容的 diskutil。
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromBSDName(nil, session, request.deviceID),
              let wholeDisk = DADiskCopyWholeDisk(disk),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String,
              ["ntfs", "ufsd_ntfs", "blntfs"].contains(kind.lowercased()) else {
            throw HelperFailure(message: "未确认选定外部 NTFS 卷及其整盘，已停止弹出。")
        }
        self.request = request
        self.userID = userID
        self.session = session
        self.disk = disk
        self.wholeDisk = wholeDisk
        media = DADiskCopyIOMedia(disk)
        wholeMedia = DADiskCopyIOMedia(wholeDisk)
        try validateIdentity()
        wasFixedExternal = protocolLocation() == "External"
            && property(wholeMedia, "Ejectable") as? Bool == false
            && property(wholeMedia, "Removable") as? Bool == false
    }

    deinit {
        if media != 0 { IOObjectRelease(media) }
        if wholeMedia != 0 { IOObjectRelease(wholeMedia) }
    }

    // 在应用进程的后台队列执行；保持同一个句柄强引用直到最终回调。
    static func eject(request: PrivilegedEjectRequest, handle: FileHandle, userID: UInt32) async throws -> EjectReceipt {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EjectReceipt, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let receipt = try HelperEject(request: request, userID: userID).run(handle: handle)
                    continuation.resume(returning: receipt)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func run(handle: FileHandle) throws -> EjectReceipt {
        let descriptor = handle.fileDescriptor
        // 前台授权可能耗时；接收后重新核对原介质，绝不因 BSD 名相同接受替换设备。
        try validateIdentity()
        try validateDescriptor(descriptor)
        try HelperEjectPolicy.ejectWithBusyRetry(validate: {
            try self.validateIdentity()
            try self.validateDescriptor(descriptor)
            guard try self.relatedMounts().isEmpty else {
                throw HelperFailure(message: "同盘仍有已挂载分卷，未执行弹出；请关闭占用程序后重试。")
            }
        }, attempt: {
            writeflow_eject_descriptor(descriptor) == 0 ? 0 : errno
        }, wait: { usleep(100_000) })
        // DKIOCEJECT 成功后先释放本应用打开引用，再核对后置状态。
        try handle.close()
        for _ in 0..<60 {
            if IORegistryEntryInPlane(wholeMedia, kIOServicePlane) == 0 {
                return .mediaRemoved(wholeMediaRegistryID: request.wholeMediaRegistryID)
            }
            try validateIdentity()
            guard try relatedMounts().isEmpty else {
                throw HelperFailure(message: "弹出后同盘出现新挂载，暂勿断开设备。")
            }
            if wasFixedExternal,
               HelperEjectPolicy.permitsConnectedFixedMedia(
                location: protocolLocation(), ejectable: property(wholeMedia, "Ejectable") as? Bool,
                removable: property(wholeMedia, "Removable") as? Bool, openStates: try mediaOpenStates()) {
                return .fixedMediaConnected(mediaRegistryID: request.mediaRegistryID,
                    wholeMediaRegistryID: request.wholeMediaRegistryID,
                    mediaByteCount: request.mediaByteCount, wholeMediaByteCount: request.wholeMediaByteCount)
            }
            usleep(50_000)
        }
        throw HelperFailure(message: "系统已接收弹出请求，但尚未确认全部介质关闭；请刷新后确认，暂勿断开连接。")
    }

    private func protocolLocation() -> String? {
        guard let raw = IORegistryEntrySearchCFProperty(wholeMedia, kIOServicePlane,
            "Protocol Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)),
              let info = raw as? [String: Any] else { return nil }
        return info["Physical Interconnect Location"] as? String
    }

    private func mediaOpenStates() throws -> [Bool?] {
        var values: [Bool?] = [property(wholeMedia, "Open") as? Bool]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(wholeMedia, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            throw HelperFailure(message: "无法确认同盘所有介质的关闭状态。")
        }
        defer { IOObjectRelease(iterator) }
        var item = IOIteratorNext(iterator)
        while item != 0 {
            if IOObjectConformsTo(item, "IOMedia") != 0 { values.append(property(item, "Open") as? Bool) }
            IOObjectRelease(item)
            item = IOIteratorNext(iterator)
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw HelperFailure(message: "介质关闭清单已变化，暂勿断开设备。") }
        try validateIdentity()
        return values
    }

    func validateIdentity() throws {
        var mediaID: UInt64 = 0, wholeID: UInt64 = 0
        guard media != 0, wholeMedia != 0,
              IORegistryEntryInPlane(media, kIOServicePlane) != 0,
              IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS,
              mediaID == request.mediaRegistryID, wholeID == request.wholeMediaRegistryID,
              property(media, "BSD Name") as? String == request.deviceID,
              property(wholeMedia, "BSD Name") as? String == request.wholeDiskID,
              (property(media, "Size") as? NSNumber)?.int64Value == request.mediaByteCount,
              (property(wholeMedia, "Size") as? NSNumber)?.int64Value == request.wholeMediaByteCount,
              property(wholeMedia, "Whole") as? Bool == true,
              let raw = IORegistryEntrySearchCFProperty(wholeMedia, kIOServicePlane,
                  "Protocol Characteristics" as CFString, kCFAllocatorDefault,
                  IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)),
              let protocolInfo = raw as? [String: Any],
              protocolInfo["Physical Interconnect Location"] as? String == "External"
                || (protocolInfo["Physical Interconnect"] as? String == "Virtual Interface"
                    && protocolInfo["Physical Interconnect Location"] as? String == "File") else {
            throw HelperFailure(message: "原介质已移除、身份变化或不是可弹出的外部整盘，已停止操作。")
        }
    }

    private func validateDescriptor(_ descriptor: Int32) throws {
        guard let majorNumber = property(wholeMedia, "BSD Major") as? NSNumber,
              let minorNumber = property(wholeMedia, "BSD Minor") as? NSNumber else {
            throw HelperFailure(message: "无法核对整盘设备描述符，已停止操作。")
        }
        try Self.validateDescriptor(descriptor, major: majorNumber.uint32Value, minor: minorNumber.uint32Value)
    }

    static func validateDescriptor(_ descriptor: Int32, major: UInt32, minor: UInt32) throws {
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 0, fstat(descriptor, &status) == 0,
              flags >= 0, flags & O_ACCMODE == O_RDONLY, flags & O_EVTONLY == 0,
              status.st_mode & S_IFMT == S_IFCHR,
              writeflow_device_matches(status.st_rdev, major, minor) != 0 else {
            throw HelperFailure(message: "描述符并非原整盘字符设备，已停止操作。")
        }
    }

    func relatedMounts() throws -> [MountedFileSystem] {
        var names: Set<String> = [request.wholeDiskID]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(wholeMedia, kIOServicePlane,
                IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            throw HelperFailure(message: "无法完整核对同盘分卷，已停止弹出。")
        }
        defer { IOObjectRelease(iterator) }
        var item = IOIteratorNext(iterator)
        while item != 0 {
            defer { IOObjectRelease(item); item = IOIteratorNext(iterator) }
            guard IOObjectConformsTo(item, "IOMedia") != 0 else { continue }
            guard let name = property(item, "BSD Name") as? String, VolumeRecord.validDeviceID(name) else {
                throw HelperFailure(message: "同盘分卷设备名称无法确认，已停止弹出。")
            }
            names.insert(name)
        }
        guard IOIteratorIsValid(iterator) != 0, names.contains(request.deviceID) else {
            throw HelperFailure(message: "同盘分卷清单已变化，已停止弹出。")
        }
        try validateIdentity()
        var values: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&values, MNT_NOWAIT)
        guard count > 0, let values else { throw HelperFailure(message: "无法读取系统挂载清单，已停止弹出。") }
        defer { free(values) }
        var result: [MountedFileSystem] = []
        for index in 0..<Int(count) {
            var value = values[index]
            func string<T>(_ field: inout T) -> String {
                withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            let source = string(&value.f_mntfromname)
            guard names.contains(String(source.dropFirst(5))), source.hasPrefix("/dev/") else { continue }
            let mount = MountedFileSystem(type: string(&value.f_fstypename), source: source,
                mountPoint: string(&value.f_mntonname), identity: "\(value.f_fsid.val.0):\(value.f_fsid.val.1)",
                ownerID: value.f_owner, isReadOnly: value.f_flags & UInt32(MNT_RDONLY) != 0)
            try HelperEjectPolicy.validateMount(mount, userID: userID)
            result.append(mount)
        }
        return result
    }

    private func property(_ media: io_service_t, _ name: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(media, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
