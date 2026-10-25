import Foundation
import DiskArbitration
import Darwin

struct DiskSnapshot: Sendable {
    let records: [VolumeRecord]
    let unreadableCount: Int
}

struct DiskOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor DiskService {
    private let session: DASession?
    private var bindings: [UInt64: RetainedDiskBinding] = [:]

    init() {
        session = DASessionCreate(nil)
        if let session {
            DASessionSetDispatchQueue(session, DispatchQueue(label: "com.blteam.ntfsworkbench.disk-events"))
        }
    }

    func snapshot() throws -> DiskSnapshot {
        let data = try run(["list", "-plist"])
        let list = try dictionary(data)
        guard let identifiers = list["AllDisks"] as? [String] else {
            throw DiskOperationError(message: "系统未返回有效磁盘列表。")
        }
        var records: [VolumeRecord] = []
        var unreadable = 0
        for identifier in identifiers where VolumeRecord.validDeviceID(identifier) {
            do {
                if let volume = try record(identifier) { records.append(volume) }
                else { unreadable += 1 }
            } catch { unreadable += 1 }
        }
        let currentIDs = Set(records.compactMap(\.mediaRegistryID))
        bindings = bindings.filter { currentIDs.contains($0.key) }
        return DiskSnapshot(records: records, unreadableCount: unreadable)
    }

    func record(_ identifier: String) throws -> VolumeRecord? {
        guard VolumeRecord.validDeviceID(identifier) else {
            throw DiskOperationError(message: "设备标识无效。")
        }
        let info = try dictionary(run(["info", "-plist", identifier]))
        let mounted = (info["MountPoint"] as? String).flatMap { MountedFileSystemReader.read(path: $0) }
        guard let record = VolumeRecord(info: info), let session,
              let binding = RetainedDiskBinding(session: session, expected: record) else {
            return VolumeRecord(info: info, mountedFileSystem: mounted)
        }
        bindings[binding.mediaRegistryID] = binding
        return VolumeRecord(info: info, mediaRegistryID: binding.mediaRegistryID,
                            wholeMediaRegistryID: binding.wholeMediaRegistryID, mountedFileSystem: mounted)
    }

    func mount(_ expected: VolumeRecord, readOnly: Bool) async throws {
        guard AppCapabilities.directMountEnabled else {
            throw DiskOperationError(message: "挂载入口正在完成介质身份验证，尚未开放。")
        }
        guard let mediaID = expected.mediaRegistryID, let wholeMediaID = expected.wholeMediaRegistryID,
              let binding = bindings[mediaID],
              let current = try record(expected.id), expected.matchesMediaIdentity(of: current),
              expected.volumeUUID == current.volumeUUID, current.canOfferMount else {
            throw DiskOperationError(message: "卷身份已变化、已被挂载或不符合外部 NTFS 卷条件，请刷新后重试。")
        }
        guard readOnly || current.writableMedia == true else {
            throw DiskOperationError(message: "系统未确认介质可写，只能请求只读挂载。")
        }
        try binding.validateMediaIdentity(expected)
        if access("/dev/r\(expected.id)", readOnly ? R_OK : R_OK | W_OK) != 0 {
            let result = try await PrivilegedMountClient.mount(PrivilegedMountRequest(
                deviceID: expected.id, mediaRegistryID: mediaID,
                wholeMediaRegistryID: wholeMediaID,
                mediaByteCount: expected.mediaByteCount, readOnly: readOnly))
            guard let mounted = try record(expected.id), expected.matchesMediaIdentity(of: mounted),
                  mounted.mountPoint == result.mountPoint, mounted.isMountedByWriteFlow,
                  mounted.mountedFileSystem?.ownerID == 0,
                  mounted.mountedFileSystem?.identity == result.fileSystemIdentity,
                  PrivilegedMountConfiguration.token(mountPoint: result.mountPoint, userID: geteuid()) == result.token,
                  result.mediaRegistryID == mediaID, result.wholeMediaRegistryID == expected.wholeMediaRegistryID,
                  result.deviceID == expected.id, result.readOnly == readOnly,
                  mounted.access == (readOnly ? .readOnly : .readWrite) else {
                throw DiskOperationError(message: "管理员服务返回后未确认目标介质与挂载实例，请刷新检查。")
            }
            return
        }
        let path = try makeMountPoint()
        do {
            let options = "\(readOnly ? "ro" : "rw"),nosuid,nodev,nobrowse,writeflow-media-id=\(mediaID)"
            _ = try run(["-F", "-t", "blntfs", "-o", options, "/dev/\(expected.id)", path], executable: "/sbin/mount")
            guard let mounted = try record(expected.id), expected.matchesMediaIdentity(of: mounted),
                  mounted.mountPoint == path, mounted.isMountedByWriteFlow,
                  mounted.mountedFileSystem?.ownerID == geteuid(),
                  mounted.access == (readOnly ? .readOnly : .readWrite) else {
                throw DiskOperationError(message: "系统返回后未确认预期挂载者、介质或读写状态。请刷新检查，不会自动改动其他卷。")
            }
        } catch {
            // 只删除本次创建且未成为挂载点的空目录；不递归清理。
            if MountedFileSystemReader.read(path: path) == nil { _ = rmdir(path) }
            throw error
        }
    }

    func unmount(_ expected: VolumeRecord) async throws {
        guard expected.canOfferUnmount, let before = expected.mountedFileSystem,
              let path = expected.mountPoint,
              let current = try record(expected.id), expected.matchesMediaIdentity(of: current),
              current.mountedFileSystem == before else {
            throw DiskOperationError(message: "只允许卸载当前用户以 NTFS 畅写挂载且身份未变化的卷。")
        }
        if before.ownerID == 0, let token = PrivilegedMountConfiguration.token(mountPoint: path, userID: geteuid()) {
            // 用户上下文拥有卷访问授权，助手接收描述符后不再自行打开受保护路径。
            let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw DiskOperationError(message: "无法打开挂载根目录，已停止卸载。") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            guard MountedFileSystemReader.read(descriptor: descriptor) == before else {
                throw DiskOperationError(message: "挂载对象已变化，已停止卸载。")
            }
            try await PrivilegedMountClient.unmount(token: token, handle: handle)
            guard MountedFileSystemReader.read(path: path)?.identity != before.identity else {
                throw DiskOperationError(message: "系统仍报告原挂载对象，尚不能确认卸载完成。")
            }
            return
        }
        guard before.ownerID == geteuid() else {
            throw DiskOperationError(message: "该挂载不属于当前用户的受管挂载，已停止卸载。")
        }
        // 事件描述符可绑定挂载实例，而不会让自身成为阻止正常卸载的读引用。
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskOperationError(message: "无法打开挂载根目录，已停止卸载。") }
        defer { close(descriptor) }
        guard MountedFileSystemReader.read(descriptor: descriptor) == before else {
            throw DiskOperationError(message: "挂载对象已变化，已停止卸载。")
        }
        try Self.synchronizeAndUnmount(descriptor: descriptor)
        guard MountedFileSystemReader.read(path: path)?.identity != before.identity else {
            throw DiskOperationError(message: "系统仍报告原挂载对象，尚不能确认卸载完成。")
        }
        // 已卸载不等于整盘弹出，不能在这里报告可以拔盘。
    }

    static func synchronizeAndUnmount(
        descriptor: Int32,
        synchronize: (Int32) -> Int32 = { fsync($0) },
        dismount: (Int32, Int32) -> Int32 = { funmount($0, $1) }
    ) throws {
        guard synchronize(descriptor) == 0 else {
            let code = errno
            throw DiskOperationError(message: "同步未完成（\(code)）：\(String(cString: strerror(code)))。已保留挂载，请勿断开磁盘。")
        }
        // 使用已核对的挂载点描述符，不按可能复用的 BSD 名或路径提交卸载。
        guard dismount(descriptor, 0) == 0 else {
            let code = errno
            throw DiskOperationError(message: "卷未卸载（\(code)）：\(String(cString: strerror(code)))。请保存文件并关闭占用程序后重试；不会强制卸载。")
        }
    }

    private func makeMountPoint() throws -> String {
        let root = "/private/tmp/ntfs-writeflow-\(geteuid())"
        if mkdir(root, 0o700) != 0 && errno != EEXIST {
            throw DiskOperationError(message: "无法建立专用挂载目录。")
        }
        var info = stat()
        guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw DiskOperationError(message: "专用挂载目录的身份或权限不符，已停止操作。")
        }
        let path = root + "/" + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else { throw DiskOperationError(message: "无法建立本次挂载目录。") }
        return path
    }

    func eject(_ expected: VolumeRecord) async throws -> EjectReceipt {
        guard AppCapabilities.directEjectEnabled, expected.canOfferEject else {
            throw DiskOperationError(message: "此卷不满足外部介质的安全弹出条件。")
        }
        let fresh = try snapshot()
        guard fresh.unreadableCount == 0 else {
            throw DiskOperationError(message: "部分磁盘状态无法读取，暂不执行弹出。请刷新后再试。")
        }
        let current = fresh.records.first { $0.id == expected.id }
        let whole = fresh.records.first { $0.id == expected.wholeDiskID }
        if let reason = EjectProtection.refusal(expected: expected, current: current,
                                                wholeDisk: whole, relatedVolumes: fresh.records) {
            throw DiskOperationError(message: reason)
        }
        // 先确认服务可用，避免因服务缺失而只完成一半卸载。
        try PrivilegedMountClient.requireEnabled()
        var unmounted = false
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        do {
            // 自有卷沿用前台事件句柄与已验证的同步/卸载路径，避免后台绕过卷访问授权。
            for volume in fresh.records where volume.wholeDiskID == expected.wholeDiskID && volume.isMountedByWriteFlow {
                try Task.checkCancellation()
                try await unmount(volume)
                unmounted = true
            }
            try Task.checkCancellation()
            let ready = try snapshot()
            guard ready.unreadableCount == 0 else {
                throw DiskOperationError(message: "无法完整核对同盘分卷，已停止弹出。")
            }
            for volume in ready.records where volume.wholeDiskID == expected.wholeDiskID && volume.mountPoint != nil {
                guard !volume.isProtectedForEject, !volume.isMountedByWriteFlow,
                      volume.wholeMediaRegistryID == expected.wholeMediaRegistryID,
                      let before = volume.mountedFileSystem, let path = volume.mountPoint else {
                    throw DiskOperationError(message: "同盘挂载身份或访问条件变化，已停止弹出。")
                }
                let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw DiskOperationError(message: "无法取得同盘卷的访问句柄，请关闭占用或检查卷访问权限后重试。")
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                handles.append(handle)
                guard MountedFileSystemReader.read(descriptor: descriptor) == before else {
                    throw DiskOperationError(message: "打开时挂载实例变化，已停止弹出。")
                }
            }
            let request = PrivilegedEjectRequest(
                deviceID: expected.id, wholeDiskID: expected.wholeDiskID,
                mediaRegistryID: expected.mediaRegistryID!, wholeMediaRegistryID: expected.wholeMediaRegistryID!,
                mediaByteCount: expected.mediaByteCount, wholeMediaByteCount: whole!.mediaByteCount)
            try await PrivilegedMountClient.prepareEject(request, handles: handles)
            unmounted = true
            for handle in handles { try? handle.close() }
            handles.removeAll()
            try Task.checkCancellation()
            guard let prepared = try record(expected.id), expected.matchesMediaIdentity(of: prepared) else {
                throw DiskOperationError(message: "原介质已变化，已停止弹出。")
            }
            // 在前台用户会话请求精确设备的只读授权，避免后台守护进程申请整个磁盘访问权。
            let deviceHandle = try await AuthorizedDeviceHandle.open(wholeDiskID: expected.wholeDiskID)
            defer { try? deviceHandle.close() }
            try Task.checkCancellation()
            return try await HelperEject.eject(request: request, handle: deviceHandle, userID: geteuid())
        } catch {
            let prefix = unmounted ? "部分分卷已卸载，但整盘弹出未确认。请勿断开磁盘。\n" : ""
            throw DiskOperationError(message: prefix + error.localizedDescription)
        }
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw DiskOperationError(message: "无法解析系统返回的磁盘状态。")
        }
        return result
    }

    private func run(_ arguments: [String], executable: String = "/usr/sbin/diskutil") throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskOperationError(message: "系统磁盘操作未完成（\(process.terminationStatus)）。\n\(detail.prefix(600))")
        }
        return data
    }
}
