import Foundation
import DiskArbitration
import IOKit

struct DiskEventSnapshot: Sendable {
    let bsdName: String
    let mediaID: UInt64?
    let volumeUUID: String?
    let mediaSize: Int64
    let deviceGUID: String?
    let isInternal: Bool?
    let volumeKind: String?
    let mountPath: String?
    let contentHint: String?
}

struct DiskAutoApprovalRule: Sendable {
    let volumeUUID: String
    let mediaSize: Int64
    let deviceGUID: String?

    func matches(_ disk: DiskEventSnapshot) -> Bool {
        guard let guid = deviceGUID, !guid.isEmpty, let actualGUID = disk.deviceGUID,
              let uuid = disk.volumeUUID else { return false }
        return volumeUUID.lowercased() == uuid.lowercased() && mediaSize == disk.mediaSize
            && guid.lowercased() == actualGUID.lowercased()
    }
}

struct DiskApprovalGate {
    var rules: [DiskAutoApprovalRule] = []
    var authorizationEpoch: UInt64 = 0
    var baseline: Set<UInt64> = []
    var ready = false
    private var attempted: Set<UInt64> = []
    var observed: [UInt64: DiskEventSnapshot] = [:]

    mutating func intercept(_ disk: DiskEventSnapshot) -> Bool {
        guard ready, let id = disk.mediaID, !baseline.contains(id), !attempted.contains(id),
              disk.isInternal == false, disk.mountPath == nil, disk.mediaSize > 0,
              disk.volumeKind?.lowercased().contains("ntfs") == true,
              rules.filter({ $0.matches(disk) }).count == 1 else { return false }
        guard let rule = rules.first(where: { $0.matches(disk) }),
              !observed.contains(where: { $0.key != id && $0.value.volumeUUID?.lowercased() == rule.volumeUUID.lowercased() }) else { return false }
        observed[id] = disk
        attempted.insert(id)
        return true
    }

    mutating func suppressCurrentlyObserved() { baseline.formUnion(observed.keys) }
    mutating func suppress(mediaID: UInt64) { baseline.insert(mediaID) }

    mutating func removed(_ id: UInt64) {
        baseline.remove(id)
        attempted.remove(id)
        observed.removeValue(forKey: id)
    }
}

struct DiskEvent: Sendable {
    enum Kind: Sendable { case appeared, changed, disappeared, intercepted }
    let kind: Kind
    let snapshot: DiskEventSnapshot
    let isStartup: Bool
    // 绑定批准时实际使用的规则版本；元数据事件不携带，拦截事件缺失则拒绝。
    let authorizationEpoch: UInt64?

    init(kind: Kind, snapshot: DiskEventSnapshot, isStartup: Bool, authorizationEpoch: UInt64? = nil) {
        self.kind = kind; self.snapshot = snapshot; self.isStartup = isStartup
        self.authorizationEpoch = authorizationEpoch
    }
}

// 回调只读取DA/IORegistry的已有描述及内存规则，不等待XPC、命令或磁盘IO。
final class DiskEventMonitor: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        var gate = DiskApprovalGate()
        var snapshots: [String: DiskEventSnapshot] = [:]
        let event: @Sendable (DiskEvent) -> Void
        let ready: @Sendable () -> Void
        let trace: (@Sendable (String, DiskEventSnapshot, Bool) -> Void)?
        init(event: @escaping @Sendable (DiskEvent) -> Void, ready: @escaping @Sendable () -> Void,
             trace: (@Sendable (String, DiskEventSnapshot, Bool) -> Void)?) {
            self.event = event; self.ready = ready; self.trace = trace
        }
        func emit(_ kind: DiskEvent.Kind, _ disk: DADisk) {
            let fresh = DiskEventMonitor.snapshot(disk)
            let name = DADiskGetBSDName(disk).map { String(cString: $0) }
            let old = name.flatMap { snapshots[$0] }
            guard let value = (fresh?.mediaID == nil ? old : fresh) ?? fresh else { return }
            trace?(String(describing: kind), value, DiskEventMonitor.approvalSnapshot(value, cached: old) != nil)
            if !gate.ready, let id = value.mediaID { gate.baseline.insert(id) }
            if let id = value.mediaID { gate.observed[id] = value }
            snapshots[value.bsdName] = value
            let startup = !gate.ready || value.mediaID.map { gate.baseline.contains($0) } == true
            event(DiskEvent(kind: kind, snapshot: value, isStartup: startup))
            if case .disappeared = kind, let id = value.mediaID { gate.removed(id); snapshots.removeValue(forKey: value.bsdName) }
        }
        func prime(_ disk: DADisk) {
            guard let value = DiskEventMonitor.snapshot(disk) else { return }
            trace?("peek", value, DiskEventMonitor.approvalSnapshot(value, cached: snapshots[value.bsdName]) != nil)
            if let id = value.mediaID {
                if !gate.ready { gate.baseline.insert(id) }
                gate.observed[id] = value
            }
            snapshots[value.bsdName] = value
        }
    }
    private let queue = DispatchQueue(label: "com.blteam.ntfsworkbench.automount.events")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let baselineProvider: @Sendable () -> Set<UInt64>?
    private let state: State
    private var session: DASession?
    private var monitoringEpoch: UInt64 = 0

    init(onEvent: @escaping @Sendable (DiskEvent) -> Void,
         onReady: @escaping @Sendable () -> Void = {},
         baselineProvider: (@Sendable () -> Set<UInt64>?)? = nil,
         onTrace: (@Sendable (String, DiskEventSnapshot, Bool) -> Void)? = nil) {
        if let baselineProvider { self.baselineProvider = baselineProvider }
        else { self.baselineProvider = { Self.currentMediaIDs() } }
        state = State(event: onEvent, ready: onReady, trace: onTrace)
        queue.setSpecific(key: queueKey, value: true)
    }

    @discardableResult func start() -> Bool {
        queue.sync {
            guard session == nil else { return true }
            guard let made = DASessionCreate(nil) else { return false }
            state.gate = DiskApprovalGate()
            state.snapshots.removeAll()
            guard let baseline = baselineProvider() else { return false }
            state.gate.baseline = baseline
            monitoringEpoch &+= 1
            let epoch = monitoringEpoch
            let context = Unmanaged.passUnretained(state).toOpaque()
            DARegisterDiskPeekCallback(made, nil, 0, Self.peek, context)
            DARegisterDiskAppearedCallback(made, nil, Self.appeared, context)
            DARegisterDiskDescriptionChangedCallback(made, nil, nil, Self.changed, context)
            DARegisterDiskDisappearedCallback(made, nil, Self.disappeared, context)
            DARegisterDiskMountApprovalCallback(made, nil, Self.approval, context)
            session = made
            DASessionSetDispatchQueue(made, queue)
            // 注册重放期间的新盘也视作基线；边界不明时跳过，不争抢系统挂载。
            queue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, self.session != nil, self.monitoringEpoch == epoch else { return }
                self.state.gate.ready = true
                self.state.ready()
            }
            return true
        }
    }

    var isReady: Bool {
        if DispatchQueue.getSpecific(key: queueKey) == true { return state.gate.ready }
        return queue.sync { state.gate.ready }
    }

    func suppressCurrentlyObserved() {
        queue.async { [state] in state.gate.suppressCurrentlyObserved() }
    }

    func suppress(mediaID: UInt64) {
        queue.async { [state] in state.gate.suppress(mediaID: mediaID) }
    }

    func setApprovalRules(_ rules: [DiskAutoApprovalRule], authorizationEpoch: UInt64) {
        queue.async { [state] in
            state.gate.rules = rules
            state.gate.authorizationEpoch = authorizationEpoch
        }
    }

    func stop() {
        let stop = { [self] in
            guard let session else { return }
            monitoringEpoch &+= 1
            state.gate.ready = false
            state.gate.rules = []
            let context = Unmanaged.passUnretained(state).toOpaque()
            DAUnregisterCallback(session, unsafeBitCast(Self.peek, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.appeared, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.changed, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.disappeared, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.approval, to: UnsafeMutableRawPointer.self), context)
            DASessionSetDispatchQueue(session, nil)
            self.session = nil
            queue.async { [state] in withExtendedLifetime(state) {} }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { stop() } else { queue.sync(execute: stop) }
    }
    deinit { stop() }

    // 官方保证peek先于自动挂载及其他通知；只采集有界元数据，不拒绝或发起挂载。
    private static let peek: DADiskPeekCallback = { disk, context in
        guard let context else { return }
        Unmanaged<State>.fromOpaque(context).takeUnretainedValue().prime(disk)
    }
    private static let appeared: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<State>.fromOpaque(context).takeUnretainedValue().emit(.appeared, disk)
    }
    private static let changed: DADiskDescriptionChangedCallback = { disk, _, context in
        guard let context else { return }
        Unmanaged<State>.fromOpaque(context).takeUnretainedValue().emit(.changed, disk)
    }
    private static let disappeared: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<State>.fromOpaque(context).takeUnretainedValue().emit(.disappeared, disk)
    }
    private static let approval: DADiskMountApprovalCallback = { disk, context in
        guard let context, let fresh = snapshot(disk, allowUSBLookup: false) else { return nil }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        state.trace?("approval", fresh, approvalSnapshot(fresh, cached: state.snapshots[fresh.bsdName]) != nil)
        guard let value = approvalSnapshot(fresh, cached: state.snapshots[fresh.bsdName]) else { return nil }
        guard state.gate.intercept(value) else { return nil }
        state.event(DiskEvent(kind: .intercepted, snapshot: value, isStartup: false,
                              authorizationEpoch: state.gate.authorizationEpoch))
        return Unmanaged.passRetained(DADissenterCreate(nil, DAReturn(kDAReturnNotPermitted),
            "本盘已选择由NTFS畅写管理，正在异步挂载。" as CFString))
    }

    static func snapshot(_ disk: DADisk, allowUSBLookup: Bool = true) -> DiskEventSnapshot? {
        guard let bsd = DADiskGetBSDName(disk), let raw = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let media = DADiskCopyIOMedia(disk)
        var identity: UInt64 = 0
        if media != 0 { _ = IORegistryEntryGetRegistryEntryID(media, &identity) }
        defer { if media != 0 { IOObjectRelease(media) } }
        let uuid: String?
        if let value = raw[kDADiskDescriptionVolumeUUIDKey as String], CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            uuid = CFUUIDCreateString(nil, (value as! CFUUID)) as String
        } else { uuid = nil }
        let guid: String?
        if let bytes = raw[kDADiskDescriptionDeviceGUIDKey as String] as? Data {
            guid = bytes.map { String(format: "%02x", $0) }.joined()
        } else { guid = allowUSBLookup ? usbIdentity(media: media) : nil }
        return DiskEventSnapshot(bsdName: String(cString: bsd), mediaID: identity == 0 ? nil : identity,
            volumeUUID: uuid, mediaSize: (raw[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
            deviceGUID: guid, isInternal: raw[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            volumeKind: raw[kDADiskDescriptionVolumeKindKey as String] as? String,
            mountPath: (raw[kDADiskDescriptionVolumePathKey as String] as? URL)?.path,
            contentHint: raw[kDADiskDescriptionMediaContentKey as String] as? String)
    }

    static func approvalSnapshot(_ fresh: DiskEventSnapshot, cached: DiskEventSnapshot?) -> DiskEventSnapshot? {
        guard let cached, let id = fresh.mediaID, cached.mediaID == id,
              let uuid = fresh.volumeUUID, uuid.lowercased() == cached.volumeUUID?.lowercased(),
              fresh.mediaSize == cached.mediaSize, fresh.bsdName == cached.bsdName else { return nil }
        return DiskEventSnapshot(bsdName: fresh.bsdName, mediaID: id, volumeUUID: uuid,
            mediaSize: fresh.mediaSize, deviceGUID: fresh.deviceGUID ?? cached.deviceGUID,
            isInternal: fresh.isInternal, volumeKind: fresh.volumeKind,
            mountPath: fresh.mountPath, contentHint: fresh.contentHint)
    }

    static func usbIdentity(serial: String?, vendor: Int?, product: Int?) -> String? {
        guard let serial = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty,
              serial.utf8.count <= 128, !serial.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let vendor, let product, (0...65535).contains(vendor), (0...65535).contains(product) else { return nil }
        return "usb:\(vendor):\(product):\(serial)"
    }
    private static func usbIdentity(media: io_service_t) -> String? {
        guard media != 0 else { return nil }
        var current = media
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<32 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 || IOObjectConformsTo(current, "IOUSBDevice") != 0 {
                // 所有值从同一最近USB设备读取，缺失即停，不能继续借用上游Hub序列号。
                func property(_ key: String) -> AnyObject? {
                    IORegistryEntryCreateCFProperty(current, key as CFString, nil, 0)?.takeRetainedValue()
                }
                return usbIdentity(serial: property("USB Serial Number") as? String,
                    vendor: (property("idVendor") as? NSNumber)?.intValue,
                    product: (property("idProduct") as? NSNumber)?.intValue)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current); current = parent
        }
        return nil
    }

    private static func currentMediaIDs() -> Set<UInt64>? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values = Set<UInt64>()
        while case let media = IOIteratorNext(iterator), media != 0 {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS else {
                IOObjectRelease(media); return nil
            }
            values.insert(id)
            IOObjectRelease(media)
        }
        return values
    }
}
