import Foundation
import Darwin
import DiskArbitration
import IOKit

enum HelperCommand {
    static func mountInvocation(_ request: PrivilegedMountRequest, userID: UInt32, token: String) throws -> (String, [String]) {
        guard userID >= 501, userID != UInt32.max, UUID(uuidString: token)?.uuidString == token,
              VolumeRecord.validDeviceID(request.deviceID), request.mediaRegistryID > 0 else {
            throw HelperFailure(message: "挂载调用参数无效。")
        }
        let path = PrivilegedMountConfiguration.namespace + "/\(userID)/\(token)/volume"
        let options = "\(request.readOnly ? "ro" : "rw"),nosuid,nodev,noowners,nobrowse,writeflow-media-id=\(request.mediaRegistryID)"
        return ("/sbin/mount", ["-F", "-t", "blntfs", "-o", options, "/dev/\(request.deviceID)", path])
    }

    static func environment(for executable: String, mountUserID: UInt32? = nil) throws -> [String: String] {
        var values = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        if let mountUserID {
            guard executable == "/sbin/mount", mountUserID >= 501, mountUserID != UInt32.max else {
                throw HelperFailure(message: "仅固定挂载程序可接收可信用户身份。")
            }
            // Apple disklib/fskit_support.m 使用 SUDO_UID 设置真实UID，并保留有效root UID。
            // 仅挂载子进程接收该值；不继承用户环境、不改变多线程助手的进程凭据。
            values["SUDO_UID"] = String(mountUserID)
        }
        return values
    }

    // 调用点只使用代码内固定的系统程序与参数结构；从不解释 shell。
    static func run(_ executable: String, _ arguments: [String], mountUserID: UInt32? = nil) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = try environment(for: executable, mountUserID: mountUserID)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperFailure(message: "系统操作失败（\(process.terminationStatus)）：\(String(decoding: data.prefix(1200), as: UTF8.self))")
        }
        return data
    }
}

final class HelperMedia {
    let volume: VolumeRecord
    private let session: DASession
    private let disk: DADisk
    private let wholeDisk: DADisk
    private let media: io_service_t
    private let wholeMedia: io_service_t

    init(_ request: PrivilegedMountRequest) throws {
        guard VolumeRecord.validDeviceID(request.deviceID), request.mediaRegistryID > 0,
              request.wholeMediaRegistryID > 0, request.mediaByteCount > 0 else {
            throw HelperFailure(message: "介质请求无效。")
        }
        let data = try HelperCommand.run("/usr/sbin/diskutil", ["info", "-plist", request.deviceID])
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let volume = VolumeRecord(info: info), volume.id == request.deviceID,
              volume.isInternal == false, volume.isNTFS, volume.mediaByteCount == request.mediaByteCount,
              let session = DASessionCreate(nil),
              let disk = DADiskCreateFromBSDName(nil, session, request.deviceID),
              let whole = DADiskCopyWholeDisk(disk) else {
            throw HelperFailure(message: "未确认外部 NTFS 介质及容量，已停止操作。")
        }
        self.volume = volume
        self.session = session
        self.disk = disk
        self.wholeDisk = whole
        media = DADiskCopyIOMedia(disk)
        wholeMedia = DADiskCopyIOMedia(whole)
        try validate(request)
    }

    deinit {
        if media != 0 { IOObjectRelease(media) }
        if wholeMedia != 0 { IOObjectRelease(wholeMedia) }
    }

    func validate(_ request: PrivilegedMountRequest) throws {
        var mediaID: UInt64 = 0, wholeID: UInt64 = 0
        guard media != 0, wholeMedia != 0,
              IORegistryEntryInPlane(media, kIOServicePlane) != 0,
              IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS,
              mediaID == request.mediaRegistryID, wholeID == request.wholeMediaRegistryID,
              Self.isExternalOrFileImage(wholeMedia),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let whole = DADiskCopyDescription(wholeDisk) as? [String: Any],
              description[kDADiskDescriptionMediaBSDNameKey as String] as? String == request.deviceID,
              whole[kDADiskDescriptionMediaBSDNameKey as String] as? String == volume.wholeDiskID,
              (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value == request.mediaByteCount else {
            throw HelperFailure(message: "介质已移除或身份发生变化，已停止操作。")
        }
    }

    private static func isExternalOrFileImage(_ media: io_service_t) -> Bool {
        // 使用保留 IOMedia 的父链属性，防止只凭可复用 BSD 名读取的外部属性放行。
        guard let value = IORegistryEntrySearchCFProperty(media, kIOServicePlane,
                  "Protocol Characteristics" as CFString, kCFAllocatorDefault,
                  IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)),
              let properties = value as? [String: Any] else { return false }
        return properties["Physical Interconnect Location"] as? String == "External"
            || (properties["Physical Interconnect"] as? String == "Virtual Interface"
                && properties["Physical Interconnect Location"] as? String == "File")
    }
}
