import Foundation
import Darwin
import IOKit
import DiskArbitration

// 仅查询真实挂载提供方和当前IOMedia；不挂载、卸载或打开原始设备。
@main enum TargetProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let directory = open(CommandLine.arguments[1],O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { exit(2) };defer { close(directory) }
        guard let before = MountedFileSystemReader.read(descriptor: directory),
              before.source.range(of: #"^/dev/disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil else { exit(2) }
        let device = String(before.source.dropFirst(5))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/sbin/diskutil")
        process.arguments = ["info","-plist",device]
        process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus == 0,
              let info = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              info["DeviceIdentifier"] as? String == device,
              let match = IOBSDNameMatching(kIOMainPortDefault,0,device) else { exit(3) }
        let media = IOServiceGetMatchingService(kIOMainPortDefault,match)
        guard media != 0 else { exit(4) };defer { IOObjectRelease(media) }
        var mediaID:UInt64=0
        guard IORegistryEntryGetRegistryEntryID(media,&mediaID)==KERN_SUCCESS,
              IORegistryEntryInPlane(media,kIOServicePlane) != 0,
              MountedFileSystemReader.read(descriptor:directory) == before,
              let capacity = IORegistryEntryCreateCFProperty(media,"Size" as CFString,nil,0)?.takeRetainedValue() as? NSNumber else { exit(5) }
        // 依据持有的DA/IOMedia父链，不把diskutil缺省键当作实体或镜像。
        guard let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, device),
              let wholeDisk = DADiskCopyWholeDisk(disk),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let whole = DADiskCopyDescription(wholeDisk) as? [String: Any] else { exit(5) }
        let daMedia = DADiskCopyIOMedia(disk), wholeMedia = DADiskCopyIOMedia(wholeDisk)
        defer { if daMedia != 0 { IOObjectRelease(daMedia) }; if wholeMedia != 0 { IOObjectRelease(wholeMedia) } }
        var daMediaID: UInt64 = 0, wholeID: UInt64 = 0
        let wholeName = whole[kDADiskDescriptionMediaBSDNameKey as String] as? String
        let expectedWhole = info["WholeDisk"] as? Bool == true ? device : info["ParentWholeDisk"] as? String
        guard daMedia != 0, wholeMedia != 0, IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(daMedia, &daMediaID) == KERN_SUCCESS, daMediaID == mediaID,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS, wholeID > 0,
              description[kDADiskDescriptionMediaBSDNameKey as String] as? String == device,
              wholeName != nil, wholeName == expectedWhole,
              (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value == capacity.int64Value else { exit(5) }
        let properties = IORegistryEntrySearchCFProperty(wholeMedia, kIOServicePlane,
            "Protocol Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any]
        let daInternal = PhysicalMediaEvidence.boolean(whole[kDADiskDescriptionDeviceInternalKey as String])
        let daProtocol = whole[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let virtual = PhysicalMediaEvidence.virtual(info: info, daInternal: daInternal, daProtocol: daProtocol, properties: properties)
        let internalDisk = PhysicalMediaEvidence.boolean(info["Internal"])
        var directoryStat=stat()
        var repeatedID: UInt64 = 0
        guard fstat(directory,&directoryStat)==0, MountedFileSystemReader.read(descriptor:directory) == before,
              IORegistryEntryInPlane(media,kIOServicePlane) != 0, IORegistryEntryInPlane(wholeMedia,kIOServicePlane) != 0,
              IORegistryEntryGetRegistryEntryID(media,&repeatedID)==KERN_SUCCESS, repeatedID == mediaID else { exit(5) }
        var result:[String:Any] = ["provider":before.type,"mount_owner_uid":before.ownerID,"media_id":mediaID,"capacity":capacity.int64Value,
            "internal":internalDisk as Any? ?? NSNull(),"virtual":virtual as Any? ?? NSNull(),"read_only":before.isReadOnly,
            "whole_media_id":wholeID,"whole_device":wholeName!,
            "physical_evidence":["da_internal":daInternal as Any? ?? NSNull(),"da_protocol":daProtocol as Any? ?? NSNull(),
                "interconnect":properties?["Physical Interconnect"] ?? NSNull(),"location":properties?["Physical Interconnect Location"] ?? NSNull()],
            "directory_empty_acl":BenchmarkIsolation.emptyACL(directory),"directory_device":directoryStat.st_dev,"directory_inode":directoryStat.st_ino,
            "source":before.source,"mount_identity":before.identity,"mount_point":before.mountPoint]
        if let isolation=BenchmarkIsolation.proof(path:CommandLine.arguments[1],mounted:before) { result["isolation"]=isolation }
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
