import Foundation
import DiskArbitration
import IOKit

// 保留介质对象用于清单与挂载前核验；整盘弹出由管理员服务持有设备句柄完成。
final class RetainedDiskBinding: @unchecked Sendable {
    let mediaRegistryID: UInt64
    let wholeMediaRegistryID: UInt64
    private let session: DASession
    private let disk: DADisk
    private let wholeDisk: DADisk
    private let media: io_service_t
    private let wholeMedia: io_service_t

    init?(session: DASession, expected: VolumeRecord) {
        guard let disk = DADiskCreateFromBSDName(nil, session, expected.id),
              let whole = DADiskCopyWholeDisk(disk) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        let wholeMedia = DADiskCopyIOMedia(whole)
        var mediaID: UInt64 = 0
        var wholeID: UInt64 = 0
        guard media != 0, wholeMedia != 0,
              IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS else {
            if media != 0 { IOObjectRelease(media) }
            if wholeMedia != 0 { IOObjectRelease(wholeMedia) }
            return nil
        }
        self.session = session
        self.disk = disk
        wholeDisk = whole
        self.media = media
        self.wholeMedia = wholeMedia
        mediaRegistryID = mediaID
        wholeMediaRegistryID = wholeID
        guard let description = Self.description(disk),
              let wholeDescription = Self.description(whole),
              Self.string(description, kDADiskDescriptionMediaBSDNameKey) == expected.id,
              Self.string(wholeDescription, kDADiskDescriptionMediaBSDNameKey) == expected.wholeDiskID,
              (expected.volumeUUID == nil || Self.uuid(description)?.lowercased() == expected.volumeUUID?.lowercased()),
              (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value == expected.mediaByteCount,
              IORegistryEntryInPlane(media, kIOServicePlane) != 0,
              IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0 else { return nil }
    }

    deinit {
        IOObjectRelease(media)
        IOObjectRelease(wholeMedia)
    }

    func validateMediaIdentity(_ expected: VolumeRecord) throws {
        var mediaID: UInt64 = 0
        var wholeID: UInt64 = 0
        guard IORegistryEntryInPlane(media, kIOServicePlane) != 0,
              IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS,
              mediaID == expected.mediaRegistryID, wholeID == expected.wholeMediaRegistryID,
              let description = Self.description(disk),
              Self.string(description, kDADiskDescriptionMediaBSDNameKey) == expected.id,
              (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value == expected.mediaByteCount,
              expected.isInternal == false else {
            throw DiskOperationError(message: "原介质已移除或身份已变化，已停止挂载。")
        }
    }

    private static func description(_ disk: DADisk) -> [String: Any]? {
        DADiskCopyDescription(disk) as? [String: Any]
    }

    private static func string(_ description: [String: Any], _ key: CFString) -> String? {
        description[key as String] as? String
    }

    private static func uuid(_ description: [String: Any]) -> String? {
        guard let value = description[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(nil, (value as! CFUUID)) as String
    }
}
