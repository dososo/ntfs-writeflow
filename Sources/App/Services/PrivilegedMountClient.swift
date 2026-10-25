import Foundation
import ServiceManagement

enum PrivilegedMountClient {
    static func requireEnabled() throws {
        guard SMAppService.daemon(plistName: PrivilegedMountConfiguration.daemonPlistName).status == .enabled else {
            throw DiskOperationError(message: "物理磁盘挂载和安全弹出需要管理员服务。请在设置中配置并按系统提示授权。")
        }
    }

    static func prepareEject(_ request: PrivilegedEjectRequest, handles: [FileHandle]) async throws {
        let data = try JSONEncoder().encode(request)
        _ = try await call { service, finish in
            service.prepareEject(data, handles: handles) { error in finish(Data(), error) }
        }
    }

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
        try requireEnabled()
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: PrivilegedMountConfiguration.machServiceName, options: .privileged)
            connection.setCodeSigningRequirement(PrivilegedMountConfiguration.helperRequirement)
            let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
            interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
                for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
            connection.remoteObjectInterface = interface
            let reply = HelperReply(continuation: continuation, connection: connection)
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

private final class HelperReply: @unchecked Sendable {
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
