// 仅供本文件无参数自建镜像入口使用；沿用正式协议/签名要求，不注册服务、不改服务端策略。
import Foundation

private enum OwnedHelperClient {
    static func mount(_ request: PrivilegedMountRequest) async throws -> PrivilegedMountResult {
        let data = try JSONEncoder().encode(request)
        let reply = try await call { service, finish in service.mount(data, withReply: finish) }
        return try JSONDecoder().decode(PrivilegedMountResult.self, from: reply)
    }

    static func unmount(token: String, handle: FileHandle) async throws {
        _ = try await call { service, finish in
            service.unmount(token, handle: handle) { error in finish(Data(), error) }
        }
    }

    static func mountedVolumes() async throws -> [PrivilegedMountResult] {
        let data = try await call { service, finish in service.mountedVolumes(withReply: finish) }
        return try JSONDecoder().decode([PrivilegedMountResult].self, from: data)
    }

    private static func call(_ send: (PrivilegedMountProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: PrivilegedMountConfiguration.machServiceName, options: .privileged)
            connection.setCodeSigningRequirement(PrivilegedMountConfiguration.helperRequirement)
            let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
            interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
                for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
            connection.remoteObjectInterface = interface
            let reply = OwnedHelperReply(continuation: continuation, connection: connection)
            connection.invalidationHandler = { reply.finish(nil, "挂载服务连接已关闭，请确认系统授权后重试。") }
            connection.interruptionHandler = { reply.finish(nil, "挂载服务中断，请刷新检查实际磁盘状态。") }
            connection.activate()
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.finish(nil, "挂载服务调用失败：\(error.localizedDescription)")
            }) as? PrivilegedMountProtocol else {
                reply.finish(nil, "无法建立挂载服务连接。")
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                reply.finish(nil, "挂载服务等待超时。操作可能已提交，请刷新确认状态后再试。")
            }
            send(service) { data, error in reply.finish(data, error) }
        }
    }
}

private final class OwnedHelperReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<Data, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ data: Data?, _ error: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidate()
        if let error { pending.resume(throwing: DiskOperationError(message: error)) }
        else if let data { pending.resume(returning: data) }
        else { pending.resume(throwing: DiskOperationError(message: "挂载服务未返回有效结果。")) }
    }
}

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
    var helperTicket: PrivilegedMountResult?
    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("writeflow-permission-probe-" + UUID().uuidString)
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
        _ = try command(root.appendingPathComponent("build/engine/arm64/ntfsprogs/mkntfs").path,["-F","-Q","-L","WF_PERMISSIONS",image.path])
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

}
@main enum HelperPermissionProbe {
 @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 1 else { exit(2) }
    let fixture = try OwnedImage()
    var result: [String: Any] = ["范围":"仅本次新建128MiB镜像；显式使用已授权管理员助手；root/ACL隔离FD验证，内部执行器写4MiB并全量复读，不代表物理性能验收"]
    do {
        let initial=try fixture.attach()
        try fixture.verify()
        guard let fresh=try await fixture.disks.record(initial.id),fresh.mountPoint==nil else { throw NSError(domain:"本次镜像已被其他提供方挂载，保留拒绝",code:1) }
        guard let media=fresh.mediaRegistryID,let whole=fresh.wholeMediaRegistryID else { throw NSError(domain:"本次镜像缺真实介质绑定",code:1) }
        let helper=try await OwnedHelperClient.mount(PrivilegedMountRequest(deviceID:fresh.id,mediaRegistryID:media,wholeMediaRegistryID:whole,mediaByteCount:fresh.mediaByteCount,readOnly:false))
        fixture.helperTicket=helper
        guard helper.deviceID==fresh.id,helper.mediaRegistryID==media,helper.wholeMediaRegistryID==whole,
              PrivilegedMountConfiguration.token(mountPoint:helper.mountPoint,userID:geteuid())==helper.token else { throw NSError(domain:"助手回包不属于本次镜像",code:1) }
        result["管理员助手回包"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(helper))
        guard let mounted=try await fixture.disks.record(initial.id),mounted.isMountedByWriteFlow,mounted.access == .readWrite,let path=mounted.mountPoint else { throw NSError(domain:"非本次blntfs读写挂载",code:1) }
        guard mounted.mountedFileSystem?.ownerID==0,PrivilegedMountConfiguration.token(mountPoint:path,userID:geteuid())==helper.token,
              mounted.mountedFileSystem?.identity==helper.fileSystemIdentity else { throw NSError(domain:"没有验证root助手挂载实例",code:1) }
        let dir=URL(fileURLWithPath:path).appendingPathComponent("本轮新建权限检查-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let fd=open(dir.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard fd>=0 else { throw NSError(domain:"无法打开目录FD",code:Int(errno)) }
        defer { close(fd) }
        var attrs=stat()
        guard fstat(fd,&attrs)==0 else { throw NSError(domain:"fstat失败",code:Int(errno)) }
        guard let observed=MountedFileSystemReader.read(descriptor:fd) else { throw NSError(domain:"真实statfs失败",code:1) }
        result["目录FD观察"]=["uid":attrs.st_uid,"gid":attrs.st_gid,"mode":String(format:"%o",attrs.st_mode & 0o777),"inode":attrs.st_ino,"device":attrs.st_dev,"本机uid":getuid(),"目录":dir.path,"实际文件系统":observed.type]
        var diagnostics:[[String:Any]]=[]
        for item in ["/","/private","/private/var","/private/var/db",PrivilegedMountConfiguration.namespace,PrivilegedMountConfiguration.namespace+"/\(geteuid())",URL(fileURLWithPath:path).deletingLastPathComponent().path,path,dir.path] {
            let opened=open(item,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
            if opened>=0 {
                var status=stat();_ = fstat(opened,&status)
                diagnostics.append(["path":item,"uid":status.st_uid,"mode":String(format:"%o",status.st_mode & 0o7777),"emptyACL":BenchmarkIsolation.emptyACL(opened),"filesystem":String(describing:MountedFileSystemReader.read(descriptor:opened))]);close(opened)
            }
        }
        var mountedList:UnsafeMutablePointer<statfs>?
        let mountedCount=getmntinfo(&mountedList,MNT_NOWAIT)
        if let mountedList {
            for index in 0..<Int(mountedCount) {
                var entry=mountedList[index]
                let source=withUnsafeBytes(of:&entry.f_mntfromname) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
                let identity="\(entry.f_fsid.val.0):\(entry.f_fsid.val.1)"
                if source==observed.source || identity==observed.identity { diagnostics.append(["matchedMountSource":source,"identity":identity]) }
            }
        }
        result["隔离诊断"]=diagnostics
        guard let isolation=BenchmarkIsolation.proof(path:dir.path,mounted:observed) else { throw NSError(domain:"真实卷外隔离未通过",code:1) }
        guard isolation["isolation_kind"] as? String == "helper-root-acl" else { throw NSError(domain:"未走管理员ACL隔离",code:1) }
        result["外层隔离证明"]=isolation
        let context:[String:Any] = ["target":dir.path,"image":fixture.image.path,"device":fixture.device!,
            "probe":fixture.root.appendingPathComponent("build/0.2.0/性能目标查询").path,
            "fio":fixture.root.appendingPathComponent("build/0.2.0/fio-source/fio").path,
            "manifest":fixture.root.appendingPathComponent("build/0.2.0/fio-build.json").path]
        let contextText=String(decoding:try JSONSerialization.data(withJSONObject:context),as:UTF8.self)
        let code="import sys,json;sys.path.insert(0,sys.argv[1]);from OwnedImageSmoke import run;print(json.dumps(run(json.loads(sys.argv[2])),ensure_ascii=False))"
        let smoke=try fixture.command("/usr/bin/python3",["-c",code,fixture.root.appendingPathComponent("Tests/Performance").path,contextText])
        result["4MiB隔离执行器验收"]=try JSONSerialization.jsonObject(with:smoke)
        result["结果"]="通过"
    } catch { result["结果"]="失败";result["错误"]=error.localizedDescription }
    do {
        try fixture.verify()
        if let device=fixture.device,let current=try await fixture.disks.record(String(device.dropFirst(5))),current.mountPoint != nil {
            guard current.isMountedByWriteFlow else { throw NSError(domain:"未知挂载保留现场",code:1) }
            guard let ticket=fixture.helperTicket,ticket.mountPoint==current.mountPoint,ticket.deviceID==current.id,
                  ticket.mediaRegistryID==current.mediaRegistryID,ticket.fileSystemIdentity==current.mountedFileSystem?.identity,
                  current.mountedFileSystem?.ownerID==0 else { throw NSError(domain:"没有本次助手凭据，保留未知挂载",code:1) }
            let eventFD=open(ticket.mountPoint,O_EVTONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard eventFD>=0 else { throw NSError(domain:"无法取得本次root挂载事件句柄",code:Int(errno)) }
            let eventHandle=FileHandle(fileDescriptor:eventFD,closeOnDealloc:true)
            defer { try? eventHandle.close() }
            guard MountedFileSystemReader.read(descriptor:eventFD)==current.mountedFileSystem else { throw NSError(domain:"卸载事件FD身份不符",code:1) }
            try await OwnedHelperClient.unmount(token:ticket.token,handle:eventHandle)
        }
        try fixture.verify();_ = try fixture.command("/usr/bin/hdiutil",["detach",fixture.device!]);result["镜像已正常释放"]=true
    } catch { result["释放错误"]=error.localizedDescription }
    result["命令记录"]=fixture.events
    let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:fixture.directory.appendingPathComponent("结果.json"));print(String(decoding:data,as:UTF8.self));print("证据：\(fixture.directory.path)")
    if result["结果"] as? String != "通过" || result["镜像已正常释放"] as? Bool != true { exit(1) }
 }
}
