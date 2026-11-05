import Foundation
import Darwin
import IOKit

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
        let internalDisk = info["Internal"] as? Bool ?? true
        let virtualKind = info["VirtualOrPhysical"] as? String
        var directoryStat=stat()
        guard fstat(directory,&directoryStat)==0 else { exit(5) }
        var result:[String:Any] = ["provider":before.type,"mount_owner_uid":before.ownerID,"media_id":mediaID,"capacity":capacity.int64Value,
            "internal":internalDisk,"virtual":virtualKind != "Physical","read_only":before.isReadOnly,
            "directory_empty_acl":BenchmarkIsolation.emptyACL(directory),"directory_device":directoryStat.st_dev,"directory_inode":directoryStat.st_ino,
            "source":before.source,"mount_identity":before.identity,"mount_point":before.mountPoint]
        if let isolation=BenchmarkIsolation.proof(path:CommandLine.arguments[1],mounted:before) { result["isolation"]=isolation }
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
