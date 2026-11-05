import Foundation
import DiskArbitration
import IOKit
import Darwin

// 仅由同目录Python工具传入刚创建并核验映射的虚拟介质；不请求写挂载。
private final class Probe {
    let id: UInt64
    let semaphore = DispatchSemaphore(value: 0)
    var approvals = 0
    var status: Int32 = -1
    init(id: UInt64) { self.id = id }
}
private let approve: DADiskMountApprovalCallback = { disk, pointer in
    guard let pointer, let snapshot = DiskEventMonitor.snapshot(disk, allowUSBLookup: false) else { return nil }
    let probe = Unmanaged<Probe>.fromOpaque(pointer).takeUnretainedValue()
    guard snapshot.mediaID == probe.id else { return nil }
    probe.approvals += 1
    if probe.approvals == 1 {
        return Unmanaged.passRetained(DADissenterCreate(nil, DAReturn(kDAReturnNotPermitted), "仅本次镜像机制验证" as CFString))
    }
    return nil
}
@main enum NativeProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 4, let id = UInt64(CommandLine.arguments[2]),
              let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, CommandLine.arguments[1]),
              let snapshot = DiskEventMonitor.snapshot(disk, allowUSBLookup: false), snapshot.mediaID == id else { exit(2) }
        let probe = Probe(id: id), queue = DispatchQueue(label: "writeflow.owned-image.probe")
        let context = Unmanaged.passUnretained(probe).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, approve, context)
        DASessionSetDispatchQueue(session, queue)
        defer {
            DAUnregisterCallback(session, unsafeBitCast(approve, to: UnsafeMutableRawPointer.self), context)
            DASessionSetDispatchQueue(session, nil)
        }
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, pointer in
            guard let pointer else { return }
            let probe = Unmanaged<Probe>.fromOpaque(pointer).takeUnretainedValue()
            probe.status = dissenter.map { Int32(DADissenterGetStatus($0)) } ?? 0
            probe.semaphore.signal()
        }, context)
        guard probe.semaphore.wait(timeout: .now() + 10) == .success else { exit(3) }
        let first = queue.sync { (probe.approvals, probe.status) }
        guard first.0 == 1, first.1 != 0 else {
            print("默认系统挂载请求未触发预期的一次批准取消，机制未通过；次数=\(first.0) status=\(first.1)"); exit(4)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = ["-F", "-t", "blntfs", "-o", "ro,nosuid,nodev,nobrowse,writeflow-media-id=\(id)", "/dev/" + CommandLine.arguments[1], CommandLine.arguments[3]]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(5) }
        print("一次批准取消后显式只读挂载成功；DA批准次数=\(queue.sync { probe.approvals })；仅证明本次镜像的API机制，不证明实体盘自动管理。")
    }
}
