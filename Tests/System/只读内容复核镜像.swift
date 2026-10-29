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
@main enum ReadOnlyContentProbe {
 @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 1 else { exit(2) }
    let fixture = try OwnedImage()
    var result: [String: Any] = ["范围":"仅本次新建128MiB镜像；准备本工具4MiB工作集；生产正常卸载/只读重挂；完整内容复核与只读周期整镜像SHA不变，不代表物理性能验收"]
    do {
        let initial=try fixture.attach()
        try fixture.verify()
        guard let fresh=try await fixture.disks.record(initial.id),fresh.mountPoint==nil else { throw NSError(domain:"本次镜像已被其他提供方挂载，保留拒绝",code:1) }
        try await fixture.disks.mount(fresh,readOnly:false)
        guard let mounted=try await fixture.disks.record(initial.id),mounted.isMountedByWriteFlow,mounted.access == .readWrite,let path=mounted.mountPoint else { throw NSError(domain:"非本次blntfs读写挂载",code:1) }
        let dir=URL(fileURLWithPath:path).appendingPathComponent("WriteFlow-Benchmark-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var context:[String:Any] = ["target":dir.path,"image":fixture.image.path,"device":fixture.device!,
            "source_report":fixture.directory.appendingPathComponent("原成功报告.json").resolvingSymlinksInPath().path,
            "probe":fixture.root.appendingPathComponent("build/0.2.0/性能目标查询").path,
            "fio":fixture.root.appendingPathComponent("build/0.2.0/fio-source/fio").path,
            "manifest":fixture.root.appendingPathComponent("build/0.2.0/fio-build.json").path]
        let code="import sys,json;sys.path.insert(0,sys.argv[1]);from OwnedReadOnlySmoke import stage;print(json.dumps(stage(json.loads(sys.argv[2]),sys.argv[3]),ensure_ascii=False))"
        func call(_ phase:String) throws -> Any {
            let text=String(decoding:try JSONSerialization.data(withJSONObject:context),as:UTF8.self)
            return try JSONSerialization.jsonObject(with:fixture.command("/usr/bin/python3",["-c",code,fixture.root.appendingPathComponent("Tests/Performance").path,text,phase]))
        }
        result["准备4MiB自有工作集"]=try call("prepare")
        try fixture.verify();try await fixture.disks.unmount(mounted)
        result["只读周期前镜像SHA256"]=SHA256.hash(data:try Data(contentsOf:fixture.image)).map { String(format:"%02x",$0) }.joined()
        guard let unmounted=try await fixture.disks.record(initial.id),unmounted.mountPoint==nil else { throw NSError(domain:"未正常卸载本次镜像",code:1) }
        try await fixture.disks.mount(unmounted,readOnly:true)
        guard let readOnly=try await fixture.disks.record(initial.id),readOnly.isMountedByWriteFlow,readOnly.access == .readOnly,let readOnlyPath=readOnly.mountPoint else { throw NSError(domain:"未确认本次只读重挂",code:1) }
        context["target"]=readOnlyPath
        let verification=try call("verify")
        result["真实只读完整复核"]=verification
        guard (verification as? [String:Any])?["status"] as? String == "passed" else { throw NSError(domain:"只读完整内容复核未通过",code:1) }
        result["结果"]="通过"
    } catch { result["结果"]="失败";result["错误"]=error.localizedDescription }
    do {
        try fixture.verify()
        if let device=fixture.device,let current=try await fixture.disks.record(String(device.dropFirst(5))),current.mountPoint != nil {
            guard current.isMountedByWriteFlow else { throw NSError(domain:"未知挂载保留现场",code:1) }
            try await fixture.disks.unmount(current)
        }
        try fixture.verify();_ = try fixture.command("/usr/bin/hdiutil",["detach",fixture.device!]);result["镜像已正常释放"]=true
    } catch { result["释放错误"]=error.localizedDescription }
    if let baseline=result["只读周期前镜像SHA256"] as? String {
        let after=SHA256.hash(data:try Data(contentsOf:fixture.image)).map { String(format:"%02x",$0) }.joined()
        result["只读周期后镜像SHA256"]=after;result["只读周期整镜像不变"]=(baseline==after)
        if baseline != after { result["结果"]="失败";result["错误"]="只读周期改变了整镜像内容" }
    }
    result["命令记录"]=fixture.events
    let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:fixture.directory.appendingPathComponent("结果.json"));print(String(decoding:data,as:UTF8.self));print("证据：\(fixture.directory.path)")
    if result["结果"] as? String != "通过" || result["镜像已正常释放"] as? Bool != true { exit(1) }
 }
}
