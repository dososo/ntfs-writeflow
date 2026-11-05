import Foundation
import Darwin
import CryptoKit

@MainActor private final class OwnedImage {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let directory: URL
    let image: URL
    var device: String?
    var events: [[String: Any]] = []
    let disks = DiskService()
    var mountCalls = 0
    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("writeflow-appmodel-" + UUID().uuidString)
        image = directory.appendingPathComponent("本次.img")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func command(_ executable: String, _ args: [String]) throws -> Data {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        events.append(["命令": executable, "参数": args, "退出码":p.terminationStatus, "错误":String(decoding: errors,as: UTF8.self)])
        guard p.terminationStatus == 0 else { throw NSError(domain:"命令失败",code:Int(p.terminationStatus)) }
        return data
    }
    func attach() throws -> VolumeRecord {
        guard !FileManager.default.fileExists(atPath: image.path) else { throw NSError(domain:"拒绝覆盖镜像",code:1) }
        _ = FileManager.default.createFile(atPath: image.path, contents: nil)
        let handle = try FileHandle(forWritingTo: image); try handle.truncate(atOffset:128*1024*1024); try handle.close()
        _ = try command(root.appendingPathComponent("build/engine/arm64/ntfsprogs/mkntfs").path,["-F","-Q","-L","WF_APPMODEL",image.path])
        let data = try plist(command("/usr/bin/hdiutil",["attach","-nomount","-nobrowse","-readwrite","-plist",image.path]))
        guard let entries = data["system-entities"] as? [[String: Any]], entries.count == 1, let node = entries[0]["dev-entry"] as? String,
              node.range(of:#"^/dev/disk[0-9]+$"#, options:.regularExpression) != nil else { throw NSError(domain:"映射错误",code:1) }
        device = node
        try verify()
        return try syncRecord()
    }
    func plist(_ data: Data) throws -> [String: Any] { try PropertyListSerialization.propertyList(from:data,format:nil) as! [String: Any] }
    func verify() throws {
        guard let device else { throw NSError(domain:"设备未创建",code:1) }
        let images = try plist(command("/usr/bin/hdiutil",["info","-plist"]))["images"] as! [[String: Any]]
        let ours = images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath:$0).resolvingSymlinksInPath() == image.resolvingSymlinksInPath() } == true }
        guard ours.count == 1, let entries = ours[0]["system-entities"] as? [[String: Any]], entries.count == 1,
              entries[0]["dev-entry"] as? String == device else { throw NSError(domain:"本次镜像映射已变",code:1) }
        let info = try plist(command("/usr/sbin/diskutil",["info","-plist",device]))
        guard info["VirtualOrPhysical"] as? String == "Virtual", (info["IOKitSize"] as? NSNumber)?.intValue == 128*1024*1024 else { throw NSError(domain:"非本次虚拟介质",code:1) }
    }
    func syncRecord() throws -> VolumeRecord {
        guard let device else { throw NSError(domain:"设备未创建",code:1) }
        let info = try plist(command("/usr/sbin/diskutil",["info","-plist",device]))
        guard let record = VolumeRecord(info:info) else { throw NSError(domain:"记录失败",code:1) }
        return record
    }
    func runtime(clear: Bool) -> AutoMountRuntime {
        AutoMountRuntime(record: { [self] id in try verify(); return try await disks.record(id) }, mount: { [self] record, readOnly in
            try verify(); mountCalls += 1; try await disks.mount(record,readOnly:readOnly)
        }, environment: { AutoMountEnvironment(isClear:clear,reason:"测试注入的竞争状态，未关闭真实Paragon") },sessionAllowed:{ true })
    }
    func model(clear: Bool) -> AppModel {
        let defaults = UserDefaults(suiteName:"writeflow.owned-image." + UUID().uuidString)!
        let model = AppModel(defaults:defaults,autoMountRuntime:runtime(clear:clear))
        model.autoEnabled = true
        model.extensionDiagnostic = ExtensionDiagnostic(title:"测试中",detail:"扩展由真实mount验证",isEnabled:true)
        model.mountHelperEnabled = true
        return model
    }
}
@main enum AppModelImageProbe {
 @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 1 else { exit(2) }
    let fixture = try OwnedImage()
    var result: [String: Any] = ["范围":"仅本次新建128MiB镜像；注入GUID/事件/授权版本/竞争clear/会话，真实DiskService和FSKit读写；不代表生产竞争检查或实体20轮通过"]
    do {
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/NTFSWriteFlow.app/Contents/Extensions/NTFSFileSystem.appex/Contents/MacOS/NTFSFileSystem")
        result["受测扩展SHA256"] = SHA256.hash(data:try Data(contentsOf:executable)).map { String(format:"%02x",$0) }.joined()
        let initial = try fixture.attach()
        guard let record = try await fixture.disks.record(initial.id), let media = record.mediaRegistryID else { throw NSError(domain:"缺实时身份",code:1) }
        let uuid = "test-only-" + UUID().uuidString
        func snapshot(guid: String?) -> DiskEventSnapshot { DiskEventSnapshot(bsdName:record.id,mediaID:media,volumeUUID:uuid,mediaSize:record.mediaByteCount,deviceGUID:guid,isInternal:false,volumeKind:"ntfs",mountPath:nil,contentHint:"Windows_NTFS") }
        let unknown = fixture.model(clear:false)
        let fingerprint = AutoMountFingerprint(volumeUUID:uuid,mediaByteCount:record.mediaByteCount,deviceGUID:"test-only-guid")!
        guard unknown.autoPolicyStore.setMode(.readWrite,for:fingerprint) else { throw NSError(domain:"测试政策保存失败",code:1) }
        await unknown.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:snapshot(guid:"test-only-guid"),isStartup:false,authorizationEpoch:unknown.autoPolicyEpoch))
        guard fixture.mountCalls == 0 else { throw NSError(domain:"竞争未知时执行了真实挂载",code:1) }
        unknown.stopMonitoring()
        let noGUID = fixture.model(clear:true)
        await noGUID.processAutoEvent(DiskEvent(kind:.appeared,snapshot:snapshot(guid:nil),isStartup:true))
        noGUID.setAutoMode(.readWrite,volume:record)
        await noGUID.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:snapshot(guid:nil),isStartup:false,authorizationEpoch:noGUID.autoPolicyEpoch))
        guard fixture.mountCalls == 0 else { throw NSError(domain:"无GUID执行了挂载",code:1) }
        noGUID.stopMonitoring()
        let model = fixture.model(clear:true)
        guard model.autoPolicyStore.setMode(.readWrite,for:fingerprint) else { throw NSError(domain:"测试政策保存失败",code:1) }
        await model.processAutoEvent(DiskEvent(kind:.intercepted,snapshot:snapshot(guid:"test-only-guid"),isStartup:false,authorizationEpoch:model.autoPolicyEpoch))
        guard fixture.mountCalls == 1, model.autoStatus.contains("已完成"), let mounted = try await fixture.disks.record(record.id), mounted.isMountedByWriteFlow,
              mounted.access == .readWrite, let path = mounted.mountPoint else { throw NSError(domain:"自动链未核实真实读写",code:1) }
        let payload = Data(("自动挂载真实镜像\n" + String(repeating:"验证",count:4096)).utf8)
        let file = URL(fileURLWithPath:path).appendingPathComponent("仅本次自动链验证.txt")
        try payload.write(to:file,options:.withoutOverwriting)
        let handle = try FileHandle(forWritingTo:file);try handle.synchronize();try handle.close()
        guard try Data(contentsOf:file) == payload else { throw NSError(domain:"即时复读不一致",code:1) }
        try await fixture.disks.unmount(mounted)
        try fixture.verify()
        guard let unmounted = try await fixture.disks.record(record.id) else { throw NSError(domain:"卸载后身份缺失",code:1) }
        try await fixture.disks.mount(unmounted,readOnly:true)
        guard let remounted = try await fixture.disks.record(record.id), remounted.isMountedByWriteFlow,
              remounted.access == .readOnly, let remountPath = remounted.mountPoint else { throw NSError(domain:"复读挂载失败",code:1) }
        guard try Data(contentsOf:URL(fileURLWithPath:remountPath).appendingPathComponent(file.lastPathComponent)) == payload else { throw NSError(domain:"重挂复读不一致",code:1) }
        model.stopMonitoring()
        result["结果"] = "通过";result["测试文件字节数"] = payload.count;result["测试文件SHA256"] = SHA256.hash(data:payload).map { String(format:"%02x",$0) }.joined()
        result["注入拒绝路径真实mount次数"] = 0;result["AppModel自动链真实mount次数"] = 1
    } catch { result["结果"] = "失败"; result["错误"] = error.localizedDescription }
    do {
        try fixture.verify()
        if let device = fixture.device, let current = try await fixture.disks.record(String(device.dropFirst(5))), current.mountPoint != nil {
            guard current.isMountedByWriteFlow else { throw NSError(domain:"未知挂载保留现场",code:1) }
            try await fixture.disks.unmount(current)
        }
        try fixture.verify()
        _ = try fixture.command("/usr/bin/hdiutil",["detach",fixture.device!])
        result["镜像已正常释放"] = true
    } catch { result["清理错误"] = error.localizedDescription }
    result["命令记录"] = fixture.events
    let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:fixture.directory.appendingPathComponent("结果.json"))
    print(String(decoding:data,as:UTF8.self));print("证据：\(fixture.directory.path)")
    if result["结果"] as? String != "通过" || result["镜像已正常释放"] as? Bool != true { exit(1) }
 }
}
