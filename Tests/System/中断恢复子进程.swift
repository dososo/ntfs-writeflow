import Foundation
import Darwin
import CryptoKit

private struct ProbeContext: Decodable {
    let root: String
    let image: String
    let device: String
    let mediaID: UInt64
    let capacity: Int64
    let token: String
}

@MainActor private final class InterruptionWorker {
    let context: ProbeContext
    let disks = DiskService()
    private var recordCalls = 0
    private let phase: String
    static let capacity: Int64 = 128 * 1024 * 1024
    static var payload: Data { Data((0..<65_573).map { UInt8(($0 * 17 + 3) % 251) }) }
    static let fileName = "仅本次中断恢复基准.txt"

    init(contextPath: String, phase: String) throws {
        self.phase = phase
        let fd = open(contextPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("上下文文件不可读") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, status.st_size > 0, status.st_size <= 8192 else {
            throw Self.failure("上下文不是当前用户有界普通文件")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        context = try JSONDecoder().decode(ProbeContext.self, from: handle.readToEnd() ?? Data())
        guard context.root.range(of: #"^/private/tmp/writeflow-interruption-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              contextPath == context.root + "/上下文.json", context.image == context.root + "/本次.img",
              context.device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil,
              context.capacity == Self.capacity, context.mediaID > 0,
              UUID(uuidString: context.token)?.uuidString == context.token else { throw Self.failure("上下文范围不符") }
        let rootFD = open(context.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Self.failure("无法核验本次私有目录") }
        defer { close(rootFD) }
        guard fstat(rootFD, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700 else {
            throw Self.failure("本次目录不属于当前用户或不是私有目录")
        }
        let imageFD = open(context.image, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard imageFD >= 0 else { throw Self.failure("本次镜像不可读") }
        defer { close(imageFD) }
        guard fstat(imageFD, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, status.st_size == Self.capacity else {
            throw Self.failure("本次镜像身份或容量不符")
        }
    }

    static func failure(_ text: String) -> NSError { NSError(domain: "中断恢复验收", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func emit(_ fields: [String: Any]) throws {
        var value = fields
        value["pid"] = Int(getpid()); value["token"] = context.token
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Self.failure("身份查询失败：" + String(decoding: error.prefix(600), as: UTF8.self))
        }
        return data
    }
    func verifiedRecord() async throws -> VolumeRecord {
        let info = try PropertyListSerialization.propertyList(from: command("/usr/bin/hdiutil", ["info", "-plist"]), format: nil) as? [String: Any]
        guard let images = info?["images"] as? [[String: Any]] else { throw Self.failure("镜像映射列表不可核实") }
        let target = URL(fileURLWithPath: context.image).resolvingSymlinksInPath()
        let ours = images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == target } == true }
        guard ours.count == 1, let entities = ours[0]["system-entities"] as? [[String: Any]], entities.count == 1,
              entities[0]["dev-entry"] as? String == context.device else { throw Self.failure("本次镜像映射已变化") }
        let properties = try PropertyListSerialization.propertyList(from: command("/usr/sbin/diskutil", ["info", "-plist", context.device]), format: nil) as? [String: Any]
        guard properties?["VirtualOrPhysical"] as? String == "Virtual",
              (properties?["IOKitSize"] as? NSNumber)?.int64Value == Self.capacity,
              let record = try await disks.record(String(context.device.dropFirst(5))), record.mediaRegistryID == context.mediaID else {
            throw Self.failure("本次虚拟介质、容量或登记身份不符")
        }
        return record
    }
    private func checkpoint(_ name: String, record: VolumeRecord? = nil) async throws {
        var fields: [String: Any] = ["kind": "checkpoint", "phase": name]
        if let record {
            fields["device"] = record.id; fields["media_id"] = record.mediaRegistryID
            fields["mount_point"] = record.mountPoint; fields["access"] = record.access.rawValue
            fields["provider"] = record.mountedFileSystem?.type
        }
        try emit(fields)
        while true { try await Task.sleep(for: .seconds(1)) }
    }
    private func validateOwnedMount(_ record: VolumeRecord) throws {
        guard record.isMountedByWriteFlow, record.mountedFileSystem?.ownerID == geteuid(),
              let path = record.mountPoint else { throw Self.failure("只恢复本轮当前用户的真实blntfs挂载") }
        let prefix = "/private/tmp/ntfs-writeflow-\(geteuid())/"
        guard path.hasPrefix(prefix), UUID(uuidString: String(path.dropFirst(prefix.count)))?.uuidString == String(path.dropFirst(prefix.count)) else {
            throw Self.failure("挂载不在生产私有随机目录，保留现场")
        }
    }
    func prepare() async throws {
        let record = try await verifiedRecord()
        guard record.mountPoint == nil else { throw Self.failure("准备前已有挂载，保留现场") }
        try await disks.mount(record, readOnly: false)
        let mounted = try await verifiedRecord(); try validateOwnedMount(mounted)
        guard mounted.access == .readWrite, let path = mounted.mountPoint else { throw Self.failure("准备挂载未确认读写") }
        let file = URL(fileURLWithPath: path).appendingPathComponent(Self.fileName)
        try Self.payload.write(to: file, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: file); try writer.synchronize(); try writer.close()
        guard try Data(contentsOf: file) == Self.payload else { throw Self.failure("准备基准即时复读不一致") }
        try await disks.unmount(mounted)
        guard try await verifiedRecord().mountPoint == nil else { throw Self.failure("准备后未正常卸载") }
        try emit(["kind": "result", "operation": "prepare", "status": "passed", "bytes": Self.payload.count, "sha256": Self.hash(Self.payload)])
    }
    func interruptedModel() async throws {
        let record = try await verifiedRecord()
        guard record.mountPoint == nil else { throw Self.failure("中断样本启动前已有挂载") }
        let nativeUUID = "test-only-" + context.token
        let runtime = AutoMountRuntime(record: { [self] _ in
            let actual = try await verifiedRecord(); recordCalls += 1
            if phase == "record-pending" && recordCalls == 1 { try await checkpoint("record-pending", record: actual) }
            return actual
        }, mount: { [self] candidate, readOnly in
            _ = try await verifiedRecord()
            try await disks.mount(candidate, readOnly: readOnly)
            let actual = try await verifiedRecord(); try validateOwnedMount(actual)
            guard actual.access == .readWrite else { throw Self.failure("检查点前系统未确认读写挂载") }
            try await checkpoint("mount-confirmed", record: actual)
        }, environment: { AutoMountEnvironment(isClear: true, reason: "中断样本注入clear，未停用真实第三方驱动") }, sessionAllowed: { true })
        let defaults = UserDefaults(suiteName: "writeflow.interruption." + context.token)!
        let model = AppModel(defaults: defaults, autoMountRuntime: runtime)
        model.autoEnabled = true
        model.extensionDiagnostic = ExtensionDiagnostic(title: "测试注入", detail: "真实扩展由系统挂载核实", isEnabled: true)
        model.mountHelperEnabled = true
        let fingerprint = AutoMountFingerprint(volumeUUID: nativeUUID, mediaByteCount: record.mediaByteCount, deviceGUID: "test-only-guid")!
        guard model.autoPolicyStore.setMode(.readWrite, for: fingerprint) else { throw Self.failure("测试规则保存失败") }
        if phase == "before-event" { try await checkpoint("before-event", record: record) }
        let snapshot = DiskEventSnapshot(bsdName: record.id, mediaID: record.mediaRegistryID, volumeUUID: nativeUUID,
            mediaSize: record.mediaByteCount, deviceGUID: "test-only-guid", isInternal: false, volumeKind: "ntfs", mountPath: nil, contentHint: "Windows_NTFS")
        await model.processAutoEvent(DiskEvent(kind: .intercepted, snapshot: snapshot, isStartup: false, authorizationEpoch: model.autoPolicyEpoch))
        throw Self.failure("模型未进入预期检查点，不能当作中断验收通过")
    }
    func release() async throws {
        let current = try await verifiedRecord()
        if current.mountPoint != nil {
            try validateOwnedMount(current)
            try await disks.unmount(current)
        }
        guard try await verifiedRecord().mountPoint == nil else { throw Self.failure("已知自有卷正常清理后仍有挂载") }
        try emit(["kind": "result", "operation": "release", "status": "passed"])
    }
    func recover() async throws {
        let before = try await verifiedRecord()
        var recoveredMountedVolume = false
        if before.mountPoint != nil {
            try validateOwnedMount(before)
            try await disks.unmount(before); recoveredMountedVolume = true
        }
        let clean = try await verifiedRecord()
        guard clean.mountPoint == nil else { throw Self.failure("恢复前未确认正常卸载") }
        let beforeRO = Self.hash(try Data(contentsOf: URL(fileURLWithPath: context.image)))
        try await disks.mount(clean, readOnly: true)
        let mounted = try await verifiedRecord(); try validateOwnedMount(mounted)
        guard mounted.access == .readOnly, let path = mounted.mountPoint else { throw Self.failure("恢复未确认只读") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(Self.fileName))
        guard data == Self.payload else { throw Self.failure("中断后基准文件全量复读不一致") }
        try await disks.unmount(mounted)
        guard try await verifiedRecord().mountPoint == nil else { throw Self.failure("只读恢复后仍有挂载") }
        let afterRO = Self.hash(try Data(contentsOf: URL(fileURLWithPath: context.image)))
        guard beforeRO == afterRO else { throw Self.failure("只读恢复期间整镜像改变") }
        try emit(["kind": "result", "operation": "recover", "status": "passed", "bytes": data.count,
                  "sha256": Self.hash(data), "read_only_image_unchanged": true, "recovered_mounted_volume": recoveredMountedVolume])
    }
}

@main enum InterruptionProbe {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let phase = CommandLine.arguments[1]
        guard ["prepare", "recover", "release", "before-event", "record-pending", "mount-confirmed"].contains(phase) else { exit(2) }
        do {
            let worker = try InterruptionWorker(contextPath: CommandLine.arguments[2], phase: phase)
            switch phase {
            case "prepare": try await worker.prepare()
            case "recover": try await worker.recover()
            case "release": try await worker.release()
            default: try await worker.interruptedModel()
            }
        } catch {
            let message = ["kind": "failure", "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: message) { FileHandle.standardOutput.write(data + Data([10])) }
            exit(1)
        }
    }
}
