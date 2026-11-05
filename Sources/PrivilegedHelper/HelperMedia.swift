import Foundation
import Darwin
import DiskArbitration
import IOKit

enum HelperCommand {
    static func mountInvocation(_ request: PrivilegedMountRequest, userID: UInt32, token: String) throws -> (String, [String]) {
        ("/bin/launchctl", ["asuser", String(userID), "/sbin/mount"] +
            (try systemMountArguments(request, userID: userID, token: token)))
    }

    static func systemMountArguments(_ request: PrivilegedMountRequest, userID: UInt32, token: String) throws -> [String] {
        guard userID >= 501, userID != UInt32.max, UUID(uuidString: token)?.uuidString == token,
              VolumeRecord.validDeviceID(request.deviceID), request.mediaRegistryID > 0 else {
            throw HelperFailure(message: "挂载调用参数无效。")
        }
        let path = PrivilegedMountConfiguration.namespace + "/\(userID)/\(token)/volume"
        let options = "\(request.readOnly ? "ro" : "rw"),nosuid,nodev,noowners,nobrowse,writeflow-media-id=\(request.mediaRegistryID)"
        return ["-F", "-t", "blntfs", "-o", options, "/dev/\(request.deviceID)", path]
    }

    static func environment(for executable: String, mountUserID: UInt32? = nil) throws -> [String: String] {
        var values = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        if let mountUserID {
            guard executable == "/bin/launchctl", mountUserID >= 501, mountUserID != UInt32.max else {
                throw HelperFailure(message: "仅固定挂载程序可接收可信用户身份。")
            }
            // asuser 为固定挂载子进程采用用户的 bootstrap 和安全审计会话，不改 UID。
            // mount 再用 SUDO_UID 发现用户扩展；不改变多线程助手的凭据或继承用户环境。
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

    struct Uncertain: LocalizedError {
        let processID: Int32
        var errorDescription: String? { "挂载子进程状态未知（PID \(processID)），已保留凭据；请刷新检查后正常卸载，不能视为取消完成。" }
    }

    // 旧系统身份桥和原生只读命令使用。普通文件避免后代持有Pipe使EOF等待无界；超时不等于已取消。
    static func runBridge(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> Data {
        var template = Array("/private/tmp/NTFSWriteFlow-mount-output.XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw HelperFailure(message: "无法准备挂载输出文件。") }
        defer { close(descriptor) }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard unlink(path) == 0 else { throw HelperFailure(message: "无法移除挂载输出临时路径。") }
        guard fchmod(descriptor, 0o600) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HelperFailure(message: "无法保护挂载输出文件。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = try environment(for: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        process.standardOutput = output; process.standardError = output
        do { try process.run() }
        catch { throw Uncertain(processID: 0) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { process.terminate() }
                throw Uncertain(processID: process.processIdentifier)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var received: Int
        repeat { received = pread(descriptor, &bytes, bytes.count, 0) } while received < 0 && errno == EINTR
        guard received >= 0 else { throw Uncertain(processID: process.processIdentifier) }
        let data = Data(bytes.prefix(received))
        guard process.terminationReason == .exit else { throw Uncertain(processID: process.processIdentifier) }
        guard process.terminationStatus == 0 else {
            throw HelperFailure(message: "系统操作失败（\(process.terminationStatus)）：\(String(decoding: data.prefix(1200), as: UTF8.self))")
        }
        return data
    }
}

enum FSKitMountBridge {
    static let mode = "--internal-fskit-mount"

    static func mustPreserveTicket(commandSucceeded: Bool, error: Error) -> Bool {
        commandSucceeded || error is HelperCommand.Uncertain
    }

    static func isRequired(on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        version.majorVersion < 26 && (version.majorVersion > 15 ||
            (version.majorVersion == 15 && version.minorVersion >= 4))
    }

    static func arguments(for ticket: HelperTicket) throws -> [String] {
        let request = ticket.request
        _ = try HelperCommand.systemMountArguments(request, userID: ticket.userID, token: ticket.token)
        guard request.wholeMediaRegistryID > 0, request.mediaByteCount > 0, ticket.fileSystemIdentity == nil,
              ticket.backend == nil || ticket.backend == .fsKit else {
            throw HelperFailure(message: "内部挂载凭据无效或已用于其他挂载。")
        }
        return [mode, String(ticket.userID), ticket.token, request.deviceID, String(request.mediaRegistryID),
                String(request.wholeMediaRegistryID), String(request.mediaByteCount), request.readOnly ? "ro" : "rw"]
    }

    static func parse(_ arguments: [String], on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> HelperTicket {
        guard isRequired(on: version), arguments.count == 8, arguments[0] == mode,
              let userID = UInt32(arguments[1]), String(userID) == arguments[1],
              let mediaID = UInt64(arguments[4]), String(mediaID) == arguments[4],
              let wholeID = UInt64(arguments[5]), String(wholeID) == arguments[5],
              let size = Int64(arguments[6]), String(size) == arguments[6],
              ["ro", "rw"].contains(arguments[7]) else { throw HelperFailure(message: "内部挂载模式参数或系统版本不适用。") }
        let request = PrivilegedMountRequest(deviceID: arguments[3], mediaRegistryID: mediaID,
            wholeMediaRegistryID: wholeID, mediaByteCount: size, readOnly: arguments[7] == "ro")
        let ticket = HelperTicket(userID: userID, token: arguments[2], request: request, backend: .fsKit)
        _ = try self.arguments(for: ticket)
        return ticket
    }

    static func invocation(for ticket: HelperTicket) throws -> (String, [String]) {
        let path = try LegacyRuntime.mountHelperCachePath(userID: ticket.userID, token: ticket.token)
        return ("/bin/launchctl", ["asuser", String(ticket.userID), path] + (try arguments(for: ticket)))
    }

    static func execute(_ arguments: [String]) throws -> Never {
        guard getuid() == 0, geteuid() == 0 else { throw HelperFailure(message: "内部挂载模式仅允许管理员服务启动。") }
        let ticket = try parse(arguments)
        try LegacyRuntime.verifyCurrentMountHelper(userID: ticket.userID, token: ticket.token)
        let namespace = try HelperNamespace(userID: ticket.userID)
        try HelperNamespace.UnmountLease.verifyTicket(namespace.load(ticket.token), expected: ticket)
        let media = try HelperMedia(ticket.request)
        guard media.volume.mountPoint == nil, try MountedFileSystemReader.deviceMounts(ticket.request.deviceID).isEmpty,
              ticket.request.readOnly || media.volume.writableMedia == true else {
            throw HelperFailure(message: "介质已有挂载或未确认可写，内部模式已停止。")
        }
        let mount = try HelperCommand.systemMountArguments(ticket.request, userID: ticket.userID, token: ticket.token)
        try media.validate(ticket.request)
        // 这里是重新exec后的独立进程；父daemon的线程、凭据和XPC监听均不改变。
        let result = mount[4].withCString { options in
            mount[5].withCString { device in
                mount[6].withCString { path in writeflow_exec_fskit_mount(ticket.userID, options, device, path) }
            }
        }
        throw HelperFailure(message: "内部挂载身份转换或固定程序启动失败（\(result)）。")
    }
}

enum NativeReadOnlyMount {
    // 原生只读和26前身份桥采用有界执行；建票据前扫描另按统一受管策略覆盖所有访问模式。
    static func requiresBoundedCommand(readOnly: Bool, on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        FSKitMountBridge.isRequired(on: version) || PrivilegedMountBackend.select(readOnly: readOnly, on: version) == .nativeReadOnly
    }

    static func invocation(_ request: PrivilegedMountRequest, userID: UInt32, token: String,
                           on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> (String, [String]) {
        guard PrivilegedMountBackend.select(readOnly: request.readOnly, on: version) == .nativeReadOnly,
              request.wholeMediaRegistryID > 0, request.mediaByteCount > 0 else {
            throw HelperFailure(message: "当前系统或访问模式不适用原生只读挂载。")
        }
        _ = try HelperCommand.systemMountArguments(request, userID: userID, token: token)
        let path = PrivilegedMountConfiguration.namespace + "/\(userID)/\(token)/volume"
        return ("/usr/sbin/diskutil", ["mount", "readOnly", "nobrowse", "-mountOptions", "nosuid,nodev,noowners",
                                      "-mountPoint", path, request.deviceID])
    }

    static func verifyExpected(ticket: HelperTicket, mounted: MountedFileSystem) throws {
        guard ticket.userID >= 501, ticket.userID != UInt32.max, VolumeRecord.validDeviceID(ticket.request.deviceID),
              ticket.request.mediaRegistryID > 0, ticket.request.wholeMediaRegistryID > 0, ticket.request.mediaByteCount > 0,
              ticket.backend == .nativeReadOnly, ticket.request.readOnly, mounted.type == "ntfs", mounted.isReadOnly,
              mounted.ownerID == 0, mounted.source == "/dev/\(ticket.request.deviceID)",
              PrivilegedMountConfiguration.token(mountPoint: mounted.mountPoint, userID: ticket.userID) == ticket.token,
              !mounted.identity.isEmpty, ticket.fileSystemIdentity == nil || ticket.fileSystemIdentity == mounted.identity else {
            throw HelperFailure(message: "未确认原票据对应的root专用原生只读挂载。")
        }
    }

    static func verifyFlags(_ flags: UInt32) throws {
        let required = UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE | MNT_IGNORE_OWNERSHIP)
        guard flags & required == required else { throw HelperFailure(message: "原生只读挂载的内核只读或安全标志不完整，未报告成功；请刷新后正常卸载。") }
    }

    static func verifyDescriptor(_ descriptor: Int32, ticket: HelperTicket, expected: MountedFileSystem) throws {
        try verifyExpected(ticket: ticket, mounted: expected)
        do { try ManagedUnmount.verifyDescriptor(descriptor, path: expected.mountPoint) }
        catch { throw HelperFailure(message: "原生只读挂载根目录句柄与原路径不符。") }
        var status = statfs()
        guard fstatfs(descriptor, &status) == 0 else { throw HelperFailure(message: "无法回读原生只读挂载的内核标志。") }
        try verifyFlags(status.f_flags)
        guard MountedFileSystemReader.read(descriptor: descriptor) == expected,
              MountedFileSystemReader.read(path: expected.mountPoint) == expected else {
            throw HelperFailure(message: "原生只读挂载的原句柄、路径或实例已变化。")
        }
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
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperFailure(message: "无法读取介质信息，已停止操作。")
        }
        let mounts = try MountedFileSystemReader.deviceMounts(request.deviceID)
        guard mounts.count <= 1 else { throw HelperFailure(message: "同一设备存在多个挂载，已停止操作。") }
        if let mounted = mounts.first { info["MountPoint"] = mounted.mountPoint }
        guard let volume = VolumeRecord(info: info, mountedFileSystem: mounts.first), volume.id == request.deviceID,
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

    func validateHandle(_ handle: FileHandle, request: PrivilegedMountRequest) throws {
        try validate(request)
        let descriptor = handle.fileDescriptor
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard let major = IORegistryEntryCreateCFProperty(media, "BSD Major" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              let minor = IORegistryEntryCreateCFProperty(media, "BSD Minor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFCHR,
              flags >= 0, flags & O_EVTONLY == 0, flags & O_ACCMODE == (request.readOnly ? O_RDONLY : O_RDWR),
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              writeflow_device_matches(status.st_rdev, major.uint32Value, minor.uint32Value) != 0 else {
            throw HelperFailure(message: "前台授权句柄不属于原分区或访问模式不符，已停止兼容挂载。")
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
