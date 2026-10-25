import Foundation
import Darwin

final class PrivilegedMountEngine: @unchecked Sendable {
    // 所有连接共用串行队列，避免同一凭据上的挂载、回读与卸载并行。
    let queue = DispatchQueue(label: "com.blteam.ntfsworkbench.mount-helper.operations")

    func mount(_ data: Data, userID: UInt32) throws -> Data {
        guard data.count <= 4096 else { throw HelperFailure(message: "挂载请求过大。") }
        let request = try JSONDecoder().decode(PrivilegedMountRequest.self, from: data)
        let media = try HelperMedia(request)
        guard media.volume.mountPoint == nil, request.readOnly || media.volume.writableMedia == true else {
            throw HelperFailure(message: "介质已由其他工具挂载或未确认可写，不会自动接管。")
        }
        let namespace = try HelperNamespace(userID: userID)
        var ticket = try namespace.create(request)
        let path = try namespace.mountPoint(ticket.token)
        do {
            try media.validate(request)
            // 固定挂载子进程通过系统支持的 SUDO_UID 分离用户扩展发现与 root 设备访问。
            let invocation = try HelperCommand.mountInvocation(request, userID: userID, token: ticket.token)
            _ = try HelperCommand.run(invocation.0, invocation.1, mountUserID: userID)
            let mounted = try verifiedMount(ticket, namespace: namespace)
            ticket.fileSystemIdentity = mounted.identity
            try namespace.save(ticket)
            guard mounted.isReadOnly == request.readOnly else {
                throw HelperFailure(message: "实际访问模式与请求不符，未报告挂载成功；可刷新后正常卸载此卷。")
            }
            return try JSONEncoder().encode(result(ticket, path: path, mounted: mounted))
        } catch {
            // 系统命令失败也可能已产生挂载；此时保留凭据供同一用户查询和正常卸载。
            if MountedFileSystemReader.read(path: path) == nil { try? namespace.discardUnmounted(ticket.token) }
            throw error
        }
    }

    func unmount(_ token: String, handle: FileHandle, userID: UInt32) throws {
        let namespace = try HelperNamespace(userID: userID)
        let ticket = try namespace.load(token)
        let before = try verifiedMount(ticket, namespace: namespace)
        let path = try namespace.mountPoint(token)
        let descriptor = handle.fileDescriptor
        try Self.validateUnmountDescriptor(descriptor, expected: before)
        guard fsync(descriptor) == 0 else {
            throw HelperFailure(message: "同步未完成（\(errno)），保留挂载，请勿断开磁盘。")
        }
        guard funmount(descriptor, 0) == 0 else {
            throw HelperFailure(message: "卷未卸载（\(errno)），请关闭占用程序后重试；不会强制卸载。")
        }
        guard MountedFileSystemReader.read(path: path)?.identity != before.identity else {
            throw HelperFailure(message: "系统仍报告原挂载实例，未确认卸载完成。")
        }
        try namespace.discardUnmounted(token)
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
                ticket.fileSystemIdentity = mounted.identity
                try namespace.save(ticket)
            }
            values.append(result(ticket, path: path, mounted: mounted))
        }
        return try JSONEncoder().encode(values)
    }

    func prepareEject(_ data: Data, handles: [FileHandle], userID: UInt32) throws {
        guard data.count <= 4096, handles.count <= 64 else { throw HelperFailure(message: "弹出请求过大。") }
        let request = try JSONDecoder().decode(PrivilegedEjectRequest.self, from: data)
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
        guard media.volume.mountPoint == path,
              let mounted = MountedFileSystemReader.read(path: path),
              Self.matchesOwnedMount(ticket, path: path, mounted: mounted) else {
            throw HelperFailure(message: "未确认助手拥有的预期介质、挂载实例及访问模式。")
        }
        return mounted
    }

    static func matchesOwnedMount(_ ticket: HelperTicket, path: String, mounted: MountedFileSystem) -> Bool {
        // 模式不符的失败挂载仍需可查询、同步和正常卸载，模式只决定 mount 的成功回包。
        mounted.type == "blntfs" && mounted.source == "/dev/\(ticket.request.deviceID)"
            && mounted.ownerID == 0 && mounted.mountPoint == path
            && (ticket.fileSystemIdentity == nil || ticket.fileSystemIdentity == mounted.identity)
    }

    private func result(_ ticket: HelperTicket, path: String, mounted: MountedFileSystem) -> PrivilegedMountResult {
        PrivilegedMountResult(token: ticket.token, mountPoint: path, deviceID: ticket.request.deviceID,
            mediaRegistryID: ticket.request.mediaRegistryID, wholeMediaRegistryID: ticket.request.wholeMediaRegistryID,
            fileSystemIdentity: mounted.identity, readOnly: mounted.isReadOnly)
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
