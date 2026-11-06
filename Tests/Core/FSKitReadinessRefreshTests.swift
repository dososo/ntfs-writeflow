import Foundation
import Darwin

private enum SimulatedFailure: Error { case read, rpc }
private actor SuspendedReadiness {
    var current: VolumeRecord?
    var readFails = false
    var queries = 0
    var reloads = 0
    var waiting: CheckedContinuation<[PrivilegedMountResult], Error>?
    var started: CheckedContinuation<Void, Never>?
    init(_ current: VolumeRecord) { self.current = current }
    func query() async throws -> [PrivilegedMountResult] {
        queries += 1
        return try await withCheckedThrowingContinuation {
            waiting = $0
            started?.resume(); started = nil
        }
    }
    func waitUntilQueryStarts() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func counts() -> (Int, Int) { (queries, reloads) }
    func replace(_ value: VolumeRecord?, failRead: Bool) { current = value; readFails = failRead }
    func reload(_ identifier: String) throws -> VolumeRecord? {
        reloads += 1
        if readFails { throw SimulatedFailure.read }
        return current?.id == identifier ? current : nil
    }
    func finish(_ values: [PrivilegedMountResult], failing: Bool) {
        guard let pending = waiting else { fatalError("查询未挂起") }
        waiting = nil
        if failing { pending.resume(throwing: SimulatedFailure.rpc) }
        else { pending.resume(returning: values) }
    }
}

@main enum FSKitReadinessRefreshTests {
    static func main() async {
        let a = "ABCDEFAB-2222-4333-8444-555555555555", b = "ABCDEFAB-2222-4333-8444-666666666666"
        func volume(_ token: String, fsid: String) -> VolumeRecord {
            let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
            let fs = MountedFileSystem(type:"blntfs",source:"/dev/disk99s1",mountPoint:path,identity:fsid,ownerID:0,isReadOnly:false)
            return VolumeRecord(info:["DeviceIdentifier":"disk99s1","ParentWholeDisk":"disk99","FilesystemType":"ntfs","MountPoint":path,"Internal":false,"TotalSize":4096,"WritableMedia":true],mediaRegistryID:9,wholeMediaRegistryID:8,mountedFileSystem:fs,writeReadinessRequired:true)!
        }
        let old = volume(a,fsid:"1:2"), new = volume(b,fsid:"3:4")
        let proof = PrivilegedMountResult(token:a,mountPoint:old.mountPoint!,deviceID:old.id,mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true)
        var checks = 0
        func check(_ value: Bool, _ text: String) {
            guard value else { fputs("失败：\(text)\n",stderr); exit(1) }
            checks += 1
        }
        for mode in ["替换", "消失", "读取失败", "RPC失败", "未变化"] {
            let fixture = SuspendedReadiness(old)
            let refresh = Task {
                await DiskService.recheckingWriteReadiness([old],userID:501,
                    query:{ try await fixture.query() },reload:{ try await fixture.reload($0) })
            }
            await fixture.waitUntilQueryStarts()
            await fixture.replace(mode == "消失" ? nil : (mode == "未变化" ? old : new),failRead: mode == "读取失败")
            await fixture.finish([proof], failing: mode == "RPC失败")
            let result = await refresh.value
            let counts = await fixture.counts()
            check(counts.0 == 1 && counts.1 == 1,"\(mode)：一次RPC后重新读取一次实例")
            switch mode {
            case "消失", "读取失败":
                check(result.records.isEmpty && result.unreadableCount == 1,"\(mode)：撤掉旧记录并报告清单不完整")
            case "未变化":
                check(result.records.first?.access == .readWrite && result.unreadableCount == 0,"未变化且真证明才可以绿")
            default:
                check(result.records.first?.mountedFileSystem?.identity == "3:4","\(mode)：返回B实例，不能返回旧A")
                check(result.records.first?.access == .writeNotReady,"\(mode)：迟到A证明不能贴到B，且不能缓存true")
            }
        }
        print("通过：\(checks)项可挂起RPC/同介质实例替换/消失/失败回归；无系统枚举、XPC或挂载。")
    }
}
