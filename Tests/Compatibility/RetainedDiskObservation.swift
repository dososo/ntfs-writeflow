import Foundation
import DiskArbitration
import IOKit
import Darwin

// 兼容路线的只读观察器；没有 claim、卸载或弹出入口。
// 相同快照仅表示本次观察一致，不能授权之后的异步卸载。
struct ObservedMountIdentity: Equatable {
    var fileSystemID: [Int32]
    var source: String
    var mountPoint: String
}

struct ObservedDiskIdentity: Equatable {
    var retainedMediaID: UInt64
    var namedMediaID: UInt64
    var mediaActive: Bool
    var deviceName: String
    var descriptorMount: ObservedMountIdentity

    var consistent: Bool {
        retainedMediaID != 0 && retainedMediaID == namedMediaID && mediaActive
            && !deviceName.isEmpty && descriptorMount.fileSystemID.count == 2
            && descriptorMount.source == "/dev/\(deviceName)" && !descriptorMount.mountPoint.isEmpty
    }

    func agrees(with current: Self) -> Bool { consistent && current.consistent && self == current }
}

enum DiskObservationError: Error { case unavailable }

func observeMount(descriptor: Int32) throws -> ObservedMountIdentity {
    var value = statfs()
    guard descriptor >= 0, fstatfs(descriptor, &value) == 0 else { throw DiskObservationError.unavailable }
    let source = withUnsafePointer(to: &value.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
    }
    let path = withUnsafePointer(to: &value.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
    }
    return ObservedMountIdentity(fileSystemID: [value.f_fsid.val.0, value.f_fsid.val.1], source: source, mountPoint: path)
}

final class RetainedDiskObservation {
    let disk: DADisk
    let media: io_service_t
    let descriptor: Int32
    let original: ObservedDiskIdentity

    init(disk: DADisk, descriptor: Int32) throws {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { throw DiskObservationError.unavailable }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { IOObjectRelease(media); throw DiskObservationError.unavailable }
        do {
            original = try Self.capture(disk: disk, media: media, descriptor: duplicate)
            guard original.consistent else { throw DiskObservationError.unavailable }
        } catch {
            close(duplicate)
            IOObjectRelease(media)
            throw error
        }
        self.disk = disk
        self.media = media
        self.descriptor = duplicate
    }

    deinit { close(descriptor); IOObjectRelease(media) }

    func unchanged() throws -> Bool {
        original.agrees(with: try Self.capture(disk: disk, media: media, descriptor: descriptor))
    }

    private static func capture(disk: DADisk, media: io_service_t, descriptor: Int32) throws -> ObservedDiskIdentity {
        var retainedID: UInt64 = 0
        guard IORegistryEntryInPlane(media, kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(media, &retainedID) == KERN_SUCCESS,
              let rawName = DADiskGetBSDName(disk) else { throw DiskObservationError.unavailable }
        let name = String(cString: rawName)
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { throw DiskObservationError.unavailable }
        let namedMedia = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard namedMedia != IO_OBJECT_NULL else { throw DiskObservationError.unavailable }
        defer { IOObjectRelease(namedMedia) }
        var namedID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(namedMedia, &namedID) == KERN_SUCCESS else {
            throw DiskObservationError.unavailable
        }
        return ObservedDiskIdentity(retainedMediaID: retainedID, namedMediaID: namedID, mediaActive: true,
                                    deviceName: name, descriptorMount: try observeMount(descriptor: descriptor))
    }
}
