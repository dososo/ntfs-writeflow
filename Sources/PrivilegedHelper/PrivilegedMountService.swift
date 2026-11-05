import Foundation
import Darwin

final class PrivilegedMountEngine: @unchecked Sendable {
    // 所有连接共用串行队列，避免同一凭据上的挂载、回读与卸载并行。
    let queue = DispatchQueue(label: "com.blteam.ntfsworkbench.mount-helper.operations")

    private var legacyProcesses: [String: LegacyMountProcess] = [:]

    func mount(_ data: Data, userID: UInt32) throws -> Data {
        guard StorageBackend.current == .fsKit else {
            throw HelperFailure(message: "当前系统需要前台授权设备句柄的兼容挂载流程。")
        }
        guard data.count <= 4096 else { throw HelperFailure(message: "挂载请求过大。") }
        let request = try JSONDecoder().decode(PrivilegedMountRequest.self, from: data)
        let media = try HelperMedia(request)
        guard media.volume.mountPoint == nil, try MountedFileSystemReader.deviceMounts(request.deviceID).isEmpty,
              request.readOnly || media.volume.writableMedia == true else {
            throw HelperFailure(message: "介质已由其他工具挂载或未确认可写，不会自动接管。")
        }
        let namespace = try HelperNamespace(userID: userID)
        let usesBridge = FSKitMountBridge.isRequired()
        let usesBoundedCommand = NativeReadOnlyMount.requiresBoundedCommand(readOnly: request.readOnly)
        if StorageBackend.requiresManagedMount { try namespace.requireNoPendingBridgeMount(for: request) }
        var ticket = try namespace.create(request)
        let path = try namespace.mountPoint(ticket.token)
        var bridgeCommandSucceeded = false
        do {
            try media.validate(request)
            if ticket.backend == .nativeReadOnly {
                let invocation = try NativeReadOnlyMount.invocation(request, userID: userID, token: ticket.token)
                _ = try HelperCommand.runBridge(invocation.0, invocation.1)
                bridgeCommandSucceeded = true
            } else if usesBridge {
                let runtime = try namespace.runtimeDirectory(for: ticket)
                defer { close(runtime) }
                _ = try LegacyRuntime.prepareMountHelper(in: runtime, userID: userID, token: ticket.token)
                try media.validate(request)
                let invocation = try FSKitMountBridge.invocation(for: ticket)
                _ = try HelperCommand.runBridge(invocation.0, invocation.1)
                bridgeCommandSucceeded = true
            } else {
                // 26及以上由系统mount处理SUDO_UID；不改变多线程助手的凭据。
                let invocation = try HelperCommand.mountInvocation(request, userID: userID, token: ticket.token)
                _ = try HelperCommand.run(invocation.0, invocation.1, mountUserID: userID)
            }
            let mounted = try verifiedMount(ticket, namespace: namespace)
            if ticket.backend == .nativeReadOnly {
                try verifyNativeReadOnly(ticket, namespace: namespace, mounted: mounted)
            }
            ticket.fileSystemIdentity = mounted.identity
            try namespace.save(ticket)
            guard mounted.isReadOnly == request.readOnly else {
                throw HelperFailure(message: "实际访问模式与请求不符，未报告挂载成功；可刷新后正常卸载此卷。")
            }
            var writeReady: Bool?
            if mounted.type == "blntfs", FSKitWriteReadiness.requires(backend: ticket.backend ?? .fsKit, readOnly: request.readOnly) {
                try verifyWriteReadiness(ticket, namespace: namespace, mounted: mounted, preparing: true)
                writeReady = true
            }
            return try JSONEncoder().encode(result(ticket, path: path, mounted: mounted, writeReady: writeReady))
        } catch {
            // 系统命令失败也可能已产生挂载；此时保留凭据供同一用户查询和正常卸载。
            let preserve = usesBoundedCommand && FSKitMountBridge.mustPreserveTicket(commandSucceeded: bridgeCommandSucceeded, error: error)
            if !preserve, MountedFileSystemReader.read(path: path) == nil {
                try? namespace.discardUnmounted(ticket.token)
            }
            throw error
        }
    }

    func mountLegacy(_ data: Data, handle: FileHandle, userID: UInt32) throws -> Data {
        guard StorageBackend.current == .macFUSE, data.count <= 4096 else {
            throw HelperFailure(message: "此系统或请求不适用旧后端挂载。")
        }
        if let reason = LegacyMountEnvironment.currentUnavailableReason() {
            throw HelperFailure(message: reason)
        }
        legacyProcesses = legacyProcesses.filter { $0.value.process.isRunning }
        let request = try JSONDecoder().decode(PrivilegedMountRequest.self, from: data)
        let media = try HelperMedia(request)
        guard media.volume.mountPoint == nil, try MountedFileSystemReader.deviceMounts(request.deviceID).isEmpty,
              request.readOnly || media.volume.writableMedia == true,
              !legacyProcesses.values.contains(where: { $0.mediaRegistryID == request.mediaRegistryID }) else {
            throw HelperFailure(message: "介质已有挂载或尚在处理，不会重复开启写后端。")
        }
        try media.validateHandle(handle, request: request)
        let namespace = try HelperNamespace(userID: userID)
        var ticket = try namespace.create(request)
        let path = try namespace.mountPoint(ticket.token)
        do {
            let child = try LegacyMountProcess(request, userID: userID, ticket: ticket, namespace: namespace, handle: handle)
            legacyProcesses[ticket.token] = child
            let mounted = try LegacyMountProcess.waitForMount(request, path: path,
                mounted: { MountedFileSystemReader.read(path: path) }, running: { child.process.isRunning },
                status: { child.process.terminationStatus }, validate: { try media.validate(request) })
            ticket.fileSystemIdentity = mounted.identity
            try namespace.save(ticket)
            return try JSONEncoder().encode(result(ticket, path: path, mounted: mounted))
        } catch {
            if legacyProcesses[ticket.token]?.process.isRunning != true, MountedFileSystemReader.read(path: path) == nil {
                legacyProcesses.removeValue(forKey: ticket.token)
                try? namespace.discardUnmounted(ticket.token)
            }
            throw error
        }
    }

    func unmount(_ token: String, handle: FileHandle, userID: UInt32) throws {
        let namespace = try HelperNamespace(userID: userID)
        var ticket = try namespace.load(token)
        let before = try verifiedMount(ticket, namespace: namespace)
        if #unavailable(macOS 26.0), ticket.fileSystemIdentity == nil {
            ticket.fileSystemIdentity = before.identity
            try namespace.save(ticket)
        }
        let path = try namespace.mountPoint(token)
        let descriptor = handle.fileDescriptor
        try Self.validateUnmountDescriptor(descriptor, expected: before)
        let lease: HelperNamespace.UnmountLease?
        if #available(macOS 26.0, *) { lease = nil }
        else { lease = try namespace.unmountLease(for: ticket) }
        try ManagedUnmount.synchronizeAndUnmount(descriptor: descriptor, expected: before, legacyLease: lease,
            validateMedia: { try HelperMedia(ticket.request).validate(ticket.request) })
        guard MountedFileSystemReader.read(path: path)?.identity != before.identity else {
            throw HelperFailure(message: "系统仍报告原挂载实例，未确认卸载完成。")
        }
        var closeLease: FileHandle?
        defer { try? closeLease?.close() }
        if before.type == "macfuse" {
            let child = legacyProcesses[token]?.process
            closeLease = try LegacyMountProcess.waitForClose(ticket,
                lease: { try namespace.mediaLease(for: ticket.request) }, running: { child?.isRunning ?? false },
                exitStatus: {
                    guard let child, !child.isRunning else { return nil }
                    return child.terminationReason == .exit ? child.terminationStatus : -1
                })
        }
        try namespace.discardUnmounted(token)
        legacyProcesses.removeValue(forKey: token)
    }

    static func validateUnmountDescriptor(_ descriptor: Int32, expected: MountedFileSystem) throws {
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard descriptor >= 0, fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              flags >= 0, flags & O_EVTONLY != 0,
              fcntl(descriptor, F_GETPATH, &path) == 0,
              String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == expected.mountPoint,
              MountedFileSystemReader.read(descriptor: descriptor) == expected else {
            throw HelperFailure(message: "传入句柄不是已核验的挂载根目录，已停止卸载。")
        }
    }

    func mountedVolumes(userID: UInt32) throws -> Data {
        let namespace = try HelperNamespace(userID: userID)
        var values: [PrivilegedMountResult] = []
        for token in try namespace.tokens() {
            let path = try namespace.mountPoint(token)
            guard var ticket = try Self.loadTicketIfMounted(at: path, load: { try namespace.load(token) }) else { continue }
            let mounted = try verifiedMount(ticket, namespace: namespace)
            if ticket.fileSystemIdentity == nil {
                // 恢复命令已成功但凭据更新前进程退出的窗口；先完成全部介质与挂载核验。
                if ticket.backend == .nativeReadOnly {
                    try verifyNativeReadOnly(ticket, namespace: namespace, mounted: mounted)
                }
                ticket.fileSystemIdentity = mounted.identity
                try namespace.save(ticket)
            }
            var writeReady: Bool?
            if mounted.type == "blntfs", FSKitWriteReadiness.requires(backend: ticket.backend ?? .fsKit, readOnly: ticket.request.readOnly) {
                // 恢复查询只读状态，不触发RO→RW；未知/失败不能被内核RW覆盖。
                do {
                    try verifyWriteReadiness(ticket, namespace: namespace, mounted: mounted, preparing: false)
                    writeReady = true
                } catch { writeReady = false }
            }
            values.append(result(ticket, path: path, mounted: mounted, writeReady: writeReady))
        }
        return try JSONEncoder().encode(values)
    }

    func prepareEject(_ data: Data, handles: [FileHandle], userID: UInt32) throws {
        guard data.count <= 4096, handles.count <= 64 else { throw HelperFailure(message: "弹出请求过大。") }
        let request = try JSONDecoder().decode(PrivilegedEjectRequest.self, from: data)
        var closeLease: FileHandle?
        defer { try? closeLease?.close() }
        if StorageBackend.current == .macFUSE {
            let namespace = try HelperNamespace(userID: userID)
            let media = PrivilegedMountRequest(deviceID: request.deviceID, mediaRegistryID: request.mediaRegistryID,
                wholeMediaRegistryID: request.wholeMediaRegistryID, mediaByteCount: request.mediaByteCount, readOnly: true)
            closeLease = try namespace.mediaLease(for: media)
            if let receipt = try LegacyReceipt.read(from: closeLease!.fileDescriptor) {
                try receipt.requireClean(wholeMediaRegistryID: request.wholeMediaRegistryID)
            }
        }
        try HelperEject(request: request, userID: userID).prepare(handles: handles)
    }

    static func loadTicketIfMounted(at path: String, load: () throws -> HelperTicket) throws -> HelperTicket? {
        // 创建目录后、凭据落盘前退出留下的空目录不能阻断其他挂载的恢复查询。
        guard MountedFileSystemReader.read(path: path) != nil else { return nil }
        return try load()
    }

    private func verifiedMount(_ ticket: HelperTicket, namespace: HelperNamespace) throws -> MountedFileSystem {
        let media = try HelperMedia(ticket.request)
        try media.validate(ticket.request)
        let path = try namespace.mountPoint(ticket.token)
        guard let mounted = MountedFileSystemReader.read(path: path),
              media.volume.mountPoint == path,
              Self.matchesOwnedMount(ticket, path: path, mounted: mounted) else {
            throw HelperFailure(message: "未确认助手拥有的预期介质、挂载实例及访问模式。")
        }
        return mounted
    }

    static func matchesOwnedMount(_ ticket: HelperTicket, path: String, mounted: MountedFileSystem) -> Bool {
        // 模式不符的失败挂载仍需可查询、同步和正常卸载，模式只决定 mount 的成功回包。
        mounted.isWriteFlow && ticket.matchesBackend(mounted) && mounted.source == "/dev/\(ticket.request.deviceID)"
            && mounted.ownerID == 0 && mounted.mountPoint == path
            && (ticket.fileSystemIdentity == nil || ticket.fileSystemIdentity == mounted.identity)
    }

    private func verifyNativeReadOnly(_ ticket: HelperTicket, namespace: HelperNamespace, mounted: MountedFileSystem) throws {
        let lease = try namespace.unmountLease(for: ticket)
        let descriptor = open(mounted.mountPoint, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperFailure(message: "无法持有原生只读挂载根目录句柄。") }
        defer { close(descriptor) }
        try withExtendedLifetime(lease) {
            try lease.validate()
            try HelperMedia(ticket.request).validate(ticket.request)
            try NativeReadOnlyMount.verifyDescriptor(descriptor, ticket: ticket, expected: mounted)
            try lease.validate()
        }
    }

    private func verifyWriteReadiness(_ ticket: HelperTicket, namespace: HelperNamespace,
                                      mounted: MountedFileSystem, preparing: Bool) throws {
        let descriptor = open(mounted.mountPoint, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperFailure(message: "无法持有内部写入检查的原挂载根句柄。") }
        defer { close(descriptor) }
        try Self.validateUnmountDescriptor(descriptor, expected: mounted)
        let executable = try LegacyRuntime.mountHelperCachePath(userID: ticket.userID, token: ticket.token)
        let arguments = try FSKitWriteProbe.arguments(userID: ticket.userID, token: ticket.token, preparing: preparing)
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try HelperCommand.runBridge(executable, arguments, timeout: preparing ? 15 : 1, input: input)
        try FSKitWriteReadiness.validate(data, token: ticket.token, mediaID: ticket.request.mediaRegistryID)
        try Self.validateUnmountDescriptor(descriptor, expected: mounted)
        try HelperMedia(ticket.request).validate(ticket.request)
        guard MountedFileSystemReader.read(path: mounted.mountPoint) == mounted else {
            throw HelperFailure(message: "内部写入检查后挂载实例已变化。")
        }
    }

    private func result(_ ticket: HelperTicket, path: String, mounted: MountedFileSystem,
                        writeReady: Bool? = nil) -> PrivilegedMountResult {
        PrivilegedMountResult(token: ticket.token, mountPoint: path, deviceID: ticket.request.deviceID,
            mediaRegistryID: ticket.request.mediaRegistryID, wholeMediaRegistryID: ticket.request.wholeMediaRegistryID,
            fileSystemIdentity: mounted.identity, readOnly: mounted.isReadOnly, backend: ticket.backend, writeReady: writeReady)
    }
}

private final class PrivilegedMountEndpoint: NSObject, PrivilegedMountProtocol, @unchecked Sendable {
    let userID: UInt32
    let engine: PrivilegedMountEngine

    init(userID: UInt32, engine: PrivilegedMountEngine) {
        self.userID = userID
        self.engine = engine
    }

    func mount(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        engine.queue.async {
            do { reply(try self.engine.mount(request, userID: self.userID), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func mountLegacy(_ request: Data, handle: FileHandle, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        engine.queue.async {
            defer { try? handle.close() }
            do { reply(try self.engine.mountLegacy(request, handle: handle, userID: self.userID), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func unmount(_ token: String, handle: FileHandle, withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            // XPC 传输的描述符由接收端独立拥有；强持有到操作结束，再且仅关闭一次。
            defer { try? handle.close() }
            do { try self.engine.unmount(token, handle: handle, userID: self.userID); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func mountedVolumes(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        engine.queue.async {
            do { reply(try self.engine.mountedVolumes(userID: self.userID), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func prepareEject(_ request: Data, handles: [FileHandle], withReply reply: @escaping @Sendable (String?) -> Void) {
        engine.queue.async {
            let error: String? = {
                // 先完成正常卸载并关闭接收端根句柄，再允许前台开始原始设备授权。
                defer { for handle in handles { try? handle.close() } }
                do { try self.engine.prepareEject(request, handles: handles, userID: self.userID); return nil }
                catch { return error.localizedDescription }
            }()
            reply(error)
        }
    }


}

final class PrivilegedMountListener: NSObject, NSXPCListenerDelegate {
    private let engine = PrivilegedMountEngine()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard geteuid() == 0, connection.effectiveUserIdentifier >= 501,
              connection.effectiveUserIdentifier != UInt32.max else { return false }
        // 系统在每条消息上验证签名；不根据可能复用的 PID 查询客户端身份。
        connection.setCodeSigningRequirement(PrivilegedMountConfiguration.clientRequirement)
        let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
        interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
            for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
        connection.exportedInterface = interface
        connection.exportedObject = PrivilegedMountEndpoint(userID: connection.effectiveUserIdentifier, engine: engine)
        connection.resume()
        return true
    }
}
