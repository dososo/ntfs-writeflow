import Foundation
import CryptoKit
import Darwin
import DiskArbitration
import IOKit

// 只创建并操作 build/eject-0.1.1 下本次生成的普通文件镜像，拒绝全部外部参数。
// 此测试需由发布验收明确签名为正式应用标识；它不安装或注册服务。
private struct IntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class EjectReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<String?, Never>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }
    func finish(_ message: String?) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let pending else { return }
        connection.invalidate()
        pending.resume(returning: message)
    }
}

// 放在非主线程隔离的函数中创建 XPC 回调，避免错误回调继承 @main 的隔离。
private func requestEject(_ request: PrivilegedEjectRequest, mountRoot: String? = nil) async throws -> String? {
    var handles: [FileHandle] = []
    var otherMountRoot = mountRoot
    if let mountRoot, let mounted = MountedFileSystemReader.read(path: mountRoot), mounted.type == "blntfs" {
        let service = DiskService()
        guard let record = try await service.record(request.deviceID),
              record.mediaRegistryID == request.mediaRegistryID,
              record.wholeMediaRegistryID == request.wholeMediaRegistryID,
              record.mediaByteCount == request.mediaByteCount,
              record.mountPoint == mountRoot, record.mountedFileSystem == mounted,
              !record.isProtectedForEject else {
            throw IntegrationFailure(message: "本次自有挂载的来源或介质身份不符")
        }
        do { try await service.unmount(record) }
        catch { return error.localizedDescription }
        otherMountRoot = nil
    }
    if let mountRoot = otherMountRoot {
        let fd = open(mountRoot, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IntegrationFailure(message: "无法打开本次镜像挂载根目录") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let actual = MountedFileSystemReader.read(descriptor: fd),
              actual.mountPoint == mountRoot, actual.source == "/dev/" + request.deviceID else {
            try? handle.close()
            throw IntegrationFailure(message: "事件句柄并非本次镜像挂载根目录")
        }
        handles.append(handle)
    }
    defer { for handle in handles { try? handle.close() } }
    let data = try JSONEncoder().encode(request)
    if let error = await sendPrepareEject(data, handles: handles) { return error }
    for handle in handles { try? handle.close() }
    handles.removeAll()
    let descriptor = open("/dev/r" + request.wholeDiskID, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw IntegrationFailure(message: "本次镜像只读设备打开失败：\(errno)") }
    let deviceHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? deviceHandle.close() }
    do {
        _ = try await HelperEject.eject(request: request, handle: deviceHandle, userID: geteuid())
        return nil
    } catch { return error.localizedDescription }
}

private func sendPrepareEject(_ data: Data, handles: [FileHandle]) async -> String? {
    await withCheckedContinuation { continuation in
        let connection = NSXPCConnection(machServiceName: PrivilegedMountConfiguration.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(PrivilegedMountConfiguration.helperRequirement)
        let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
        interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
            for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
        connection.remoteObjectInterface = interface
        let state = EjectReply(continuation, connection: connection)
        connection.invalidationHandler = { state.finish("XPC连接已关闭，结果未确认") }
        connection.interruptionHandler = { state.finish("XPC连接中断，结果未确认") }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            state.finish("XPC错误：\(error.localizedDescription)")
        }) as? PrivilegedMountProtocol else {
            state.finish("无法取得正式服务代理")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) {
            state.finish("等待超时：操作可能仍在进行；不得自动强制清理")
        }
        proxy.prepareEject(data, handles: handles) { error in state.finish(error) }
    }
}

private final class ImageIdentity {
    let device: String
    let request: PrivilegedEjectRequest
    private let session: DASession
    private let disk: DADisk
    private let whole: DADisk
    private let media: io_service_t
    private let wholeMedia: io_service_t

    init(device: String, info: [String: Any]) throws {
        guard let record = VolumeRecord(info: info), record.id == device,
              record.wholeDiskID == device, record.isInternal == false, record.isNTFS,
              record.mediaByteCount == 128 * 1024 * 1024, record.mountPoint == nil,
              let session = DASessionCreate(nil),
              let disk = DADiskCreateFromBSDName(nil, session, device),
              let whole = DADiskCopyWholeDisk(disk) else {
            throw IntegrationFailure(message: "新镜像未满足单整盘、NTFS、外部、128MiB且未挂载的前提")
        }
        self.device = device
        self.session = session
        self.disk = disk
        self.whole = whole
        media = DADiskCopyIOMedia(disk)
        wholeMedia = DADiskCopyIOMedia(whole)
        var mediaID: UInt64 = 0, wholeID: UInt64 = 0
        guard media != 0, wholeMedia != 0,
              IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS,
              mediaID > 0, wholeID == mediaID else {
            if media != 0 { IOObjectRelease(media) }
            if wholeMedia != 0 { IOObjectRelease(wholeMedia) }
            throw IntegrationFailure(message: "无法绑定本次新建镜像IOMedia身份")
        }
        request = PrivilegedEjectRequest(deviceID: device, wholeDiskID: device,
            mediaRegistryID: mediaID, wholeMediaRegistryID: wholeID,
            mediaByteCount: record.mediaByteCount, wholeMediaByteCount: record.mediaByteCount)
    }
    deinit { IOObjectRelease(media); IOObjectRelease(wholeMedia) }
    var isPresent: Bool { IORegistryEntryInPlane(media, kIOServicePlane) != 0 && IORegistryEntryInPlane(wholeMedia, kIOServicePlane) != 0 }
}

@main enum EjectSystemIntegration {
    static func main() async {
        guard CommandLine.arguments.count == 1 else {
            print("拒绝外部参数：本测试只能操作自己新建的可丢弃镜像。")
            exit(2)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("build/eject-0.1.1/系统验收-\(UUID().uuidString)")
        var checks: [String] = []
        var events: [[String: Any]] = []
        var attached: [(URL, ImageIdentity)] = []
        var failure: String?
        var heldFile: FileHandle?
        var heldRaw: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func command(_ program: String, _ arguments: [String]) throws -> Data {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: program)
                p.arguments = arguments
                p.standardOutput = pipe; p.standardError = pipe
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                events.append(["命令": [program] + arguments, "退出码": p.terminationStatus,
                               "输出": String(decoding: data, as: UTF8.self)])
                guard p.terminationStatus == 0 else { throw IntegrationFailure(message: "系统命令失败：\(program) \(arguments) \(p.terminationStatus)") }
                return data
            }
            func plist(_ data: Data) throws -> [String: Any] {
                guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw IntegrationFailure(message: "无法解析系统列表")
                }
                return value
            }
            func mapping(_ image: URL, device: String) throws -> Bool {
                let info = try plist(command("/usr/bin/hdiutil", ["info", "-plist"]))
                return (info["images"] as? [[String: Any]] ?? []).contains {
                    guard let path = $0["image-path"] as? String,
                          URL(fileURLWithPath: path).resolvingSymlinksInPath() == image.resolvingSymlinksInPath() else { return false }
                    return ($0["system-entities"] as? [[String: Any]] ?? []).contains { $0["dev-entry"] as? String == "/dev/" + device }
                }
            }
            func prepare(_ name: String) throws -> (URL, ImageIdentity) {
                let image = directory.appendingPathComponent(name + ".img")
                try Data().write(to: image, options: .withoutOverwriting)
                let file = try FileHandle(forWritingTo: image)
                try file.truncate(atOffset: 128 * 1024 * 1024); try file.close()
                _ = try command(root.appendingPathComponent("build/engine/arm64/ntfsprogs/mkntfs").path,
                    ["-F", "-Q", "-s", "512", "-L", "WRITEFLOW_EJECT", image.path])
                let value = try plist(command("/usr/bin/hdiutil", ["attach", "-nomount", "-nobrowse", "-plist", image.path]))
                let entries = (value["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
                try require(entries.count == 1 && entries[0].hasPrefix("/dev/disk"), "新镜像不是预期单设备")
                let device = String(entries[0].dropFirst(5))
                try require(VolumeRecord.validDeviceID(device), "附加设备标识不合法")
                try require(mapping(image, device: device), "未确认本次镜像与设备一一关联")
                let identity = try ImageIdentity(device: device, info: plist(command("/usr/sbin/diskutil", ["info", "-plist", device])))
                events.append(["镜像": image.path, "原介质身份": identity.request.mediaRegistryID,
                               "原整盘身份": identity.request.wholeMediaRegistryID, "设备": device])
                return (image, identity)
            }
            let first = try prepare("占用与身份")
            attached.append(first)
            let originalHash = try hash(first.0)
            let expected = first.1.request
            let wrong = PrivilegedEjectRequest(deviceID: expected.deviceID, wholeDiskID: expected.wholeDiskID,
                mediaRegistryID: expected.mediaRegistryID + 1, wholeMediaRegistryID: expected.wholeMediaRegistryID,
                mediaByteCount: expected.mediaByteCount, wholeMediaByteCount: expected.wholeMediaByteCount)
            let wrongResult = try await requestEject(wrong)
            events.append(["步骤": "错误介质身份", "服务回复": wrongResult ?? "无错误"])
            try require(wrongResult?.contains("原介质已移除、身份变化") == true, "错误身份未被生产身份门禁明确拒绝")
            try require(first.1.isPresent && mapping(first.0, device: first.1.device), "错误身份请求影响了原介质")
            try require(hash(first.0) == originalHash, "错误身份请求后镜像摘要改变")
            checks.append("错误介质身份请求明确拒绝，原对象与映射保留，镜像摘要不变")

            let mountBase = "/private/tmp/ntfs-writeflow-\(geteuid())"
            if mkdir(mountBase, 0o700) != 0 && errno != EEXIST {
                throw IntegrationFailure(message: "无法创建专用挂载根目录")
            }
            var baseInfo = stat()
            try require(lstat(mountBase, &baseInfo) == 0 && baseInfo.st_mode & S_IFMT == S_IFDIR
                && baseInfo.st_uid == geteuid() && baseInfo.st_mode & 0o777 == 0o700,
                "专用挂载根目录身份或权限不符")
            let path = mountBase + "/" + UUID().uuidString
            try require(mkdir(path, 0o700) == 0, "无法创建本次唯一挂载目录")
            try require(first.1.isPresent && mapping(first.0, device: first.1.device), "挂载前镜像映射变化")
            _ = try command("/sbin/mount", ["-F", "-t", "blntfs", "-o",
                "rw,nosuid,nodev,nobrowse,writeflow-media-id=\(expected.mediaRegistryID)",
                "/dev/" + first.1.device, path])
            guard let mounted = MountedFileSystemReader.read(path: path), mounted.mountPoint == path,
                  mounted.source == "/dev/" + first.1.device, mounted.type == "blntfs",
                  mounted.ownerID == geteuid(), !mounted.isReadOnly else {
                throw IntegrationFailure(message: "本次镜像未由blntfs在自有目录按当前用户读写挂载")
            }
            events.append(["步骤": "自有引擎挂载回读", "挂载根": path, "来源": mounted.source,
                           "类型": mounted.type, "所有者": mounted.ownerID])
            try require(first.1.isPresent && mapping(first.0, device: first.1.device), "挂载后新镜像身份不符")
            let file = URL(fileURLWithPath: path).appendingPathComponent("仅本次弹出占用验收.bin")
            try Data(repeating: 0x5a, count: 4096).write(to: file, options: .withoutOverwriting)
            heldFile = try FileHandle(forUpdating: file)
            try heldFile?.synchronize()
            let busy = try await requestEject(expected, mountRoot: path)
            events.append(["步骤": "保持文件打开", "服务回复": busy ?? "无错误"])
            try require(busy?.contains("（16）") == true || busy?.contains("（49168）") == true, "占用时未返回明确的占用拒绝")
            try require(first.1.isPresent && mapping(first.0, device: first.1.device), "占用拒绝未保留介质")
            try require(MountedFileSystemReader.read(path: path) == mounted, "占用拒绝后原挂载实例改变")
            checks.append("占用文件时正常卸载拒绝，原挂载实例保留，未强制弹出")
            try heldFile?.close(); heldFile = nil
            let ejected = try await requestEject(expected, mountRoot: path)
            events.append(["步骤": "关闭占用后整盘弹出", "服务回复": ejected ?? "无错误"])
            try require(ejected == nil, "关闭占用后弹出失败：\(ejected ?? "")")
            try require(!first.1.isPresent && !mapping(first.0, device: first.1.device), "成功回复后原介质或映射仍存在")
            checks.append("关闭占用后经生产服务正常卸载并整盘弹出，原对象与镜像映射消失")

            let second = try prepare("未挂载整盘")
            attached.append(second)
            let pristine = try hash(second.0)
            try require(second.1.isPresent && mapping(second.0, device: second.1.device), "额外占用前原镜像身份不符")
            heldRaw = open("/dev/r" + second.1.device, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            try require(heldRaw >= 0, "无法对本次可丢弃镜像建立额外只读设备占用")
            try require(second.1.isPresent && mapping(second.0, device: second.1.device), "额外占用后原镜像身份不符")
            let start = DispatchTime.now().uptimeNanoseconds
            let rawBusy = try await requestEject(second.1.request)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            events.append(["步骤": "持续只读原始设备占用", "服务回复": rawBusy ?? "无错误", "秒数": elapsed])
            try require(rawBusy?.contains("整盘未弹出（16）") == true, "持续设备占用时没有返回EBUSY")
            try require(elapsed >= 2.5 && elapsed < 30, "EBUSY重试应有界且未立即放弃：\(elapsed)秒")
            try require(second.1.isPresent && mapping(second.0, device: second.1.device), "持续设备占用失败后原介质应保留")
            try require(hash(second.0) == pristine, "持续设备占用拒绝改变了镜像摘要")
            checks.append("持续原始设备占用时同FD有界重试后明确拒绝，原介质与内容保留")
            close(heldRaw); heldRaw = -1
            let unmounted = try await requestEject(second.1.request)
            events.append(["步骤": "未挂载整盘弹出", "服务回复": unmounted ?? "无错误"])
            try require(unmounted == nil, "已未挂载镜像弹出失败：\(unmounted ?? "")")
            try require(!second.1.isPresent && !mapping(second.0, device: second.1.device), "未挂载镜像弹出后仍有原对象或映射")
            try require(hash(second.0) == pristine, "未挂载弹出改变了镜像摘要")
            checks.append("已卸载整盘可直接正常弹出，原对象与映射消失，镜像摘要不变")
        } catch {
            failure = error.localizedDescription
        }
        try? heldFile?.close()
        if heldRaw >= 0 { close(heldRaw) }
        // 失败不按旧设备号清理，不强制卸载；报告明确保留状态，交给验收者核验后处理。
        let evidence: [String: Any] = ["日期": ISO8601DateFormatter().string(from: Date()),
            "结果": failure == nil ? "通过" : "失败", "检查": checks, "错误": failure ?? "",
            "操作记录": events, "设备残留": attached.map { ["镜像": $0.0.path, "原介质仍存在": $0.1.isPresent] },
            "范围": "仅本次创建的128MiB普通文件镜像；未操作真实盘，不证明掉电/热拔插验收"]
        do {
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("结果.json"))
            print(String(decoding: data, as: UTF8.self))
            print("证据：\(directory.path)")
        } catch { print("保存证据失败：\(error)") }
        exit(failure == nil ? 0 : 1)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw IntegrationFailure(message: message) }
    }
    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
