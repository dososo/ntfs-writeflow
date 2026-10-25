import Foundation
import Darwin

private final class HandleReceiver: NSObject, PrivilegedMountProtocol, @unchecked Sendable {
    let expected: MountedFileSystem
    let senderDescriptor: Int32
    init(expected: MountedFileSystem, senderDescriptor: Int32) {
        self.expected = expected
        self.senderDescriptor = senderDescriptor
    }
    func mount(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) { reply(nil, "测试不挂载") }
    func prepareEject(_ request: Data, handles: [FileHandle], withReply reply: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global().async {
            var failure: String?
            do {
                guard handles.count == 1, handles[0].fileDescriptor != self.senderDescriptor else {
                    throw HelperFailure(message: "数组没有传输独立描述符")
                }
                _ = try HelperEject.validateHandles(handles, mounts: [self.expected])
            } catch { failure = error.localizedDescription }
            for handle in handles { try? handle.close() }
            reply(failure)
        }
    }
    func mountedVolumes(withReply reply: @escaping @Sendable (Data?, String?) -> Void) { reply(nil, "测试不枚举") }
    func unmount(_ token: String, handle: FileHandle, withReply reply: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global().async {
            var failure: String?
            do {
                guard handle.fileDescriptor != self.senderDescriptor else {
                    throw HelperFailure(message: "没有传输独立描述符")
                }
                try PrivilegedMountEngine.validateUnmountDescriptor(handle.fileDescriptor, expected: self.expected)
            } catch { failure = error.localizedDescription }
            try? handle.close()
            reply(failure)
        }
    }
}

private func handleTestInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: PrivilegedMountProtocol.self)
    interface.setClasses(NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>,
        for: #selector(PrivilegedMountProtocol.prepareEject(_:handles:withReply:)), argumentIndex: 1, ofReply: false)
    return interface
}

private final class HandleListener: NSObject, NSXPCListenerDelegate {
    let receiver: HandleReceiver
    init(_ receiver: HandleReceiver) { self.receiver = receiver }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = handleTestInterface()
        connection.exportedObject = receiver
        connection.resume()
        return true
    }
}

private final class TransferReply: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    func finish(_ error: String?) { lock.withLock { value = error }; semaphore.signal() }
    var error: String? { lock.withLock { value } }
}

@main enum PrivilegedHelperHandleTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        guard let root = MountedFileSystemReader.read(path: "/") else { fatalError("无法读取根文件系统状态") }
        let rootDescriptor = open("/", O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        check(rootDescriptor >= 0, "应能以当前用户打开事件描述符")
        let rootHandle = FileHandle(fileDescriptor: rootDescriptor, closeOnDealloc: true)
        defer { try? rootHandle.close() }
        try PrivilegedMountEngine.validateUnmountDescriptor(rootDescriptor, expected: root)
        count += 1

        let fixture = FileManager.default.currentDirectoryPath + "/build/helper-candidate/句柄验证-\(UUID().uuidString)"
        check(mkdir(fixture, 0o700) == 0, "只创建本次临时目录")
        let filePath = fixture + "/普通文件"
        let file = open(filePath, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        check(file >= 0, "只创建本次普通文件")
        let directory = open(fixture, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let rootRead = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer {
            close(file); close(directory); close(rootRead)
            precondition(unlink(filePath) == 0)
            precondition(rmdir(fixture) == 0)
        }
        for descriptor in [-1, file, directory, rootRead] {
            do {
                try PrivilegedMountEngine.validateUnmountDescriptor(descriptor, expected: root)
                fatalError("无效、普通文件、非根目录或非事件句柄不得通过")
            } catch let error as HelperFailure {
                check(error.message.contains("不是已核验的挂载根目录"), "拒绝应发生在同步和卸载之前")
            }
        }
        let wrong = MountedFileSystem(type: root.type, source: root.source, mountPoint: root.mountPoint,
            identity: "错误实例", ownerID: root.ownerID, isReadOnly: root.isReadOnly)
        do {
            try PrivilegedMountEngine.validateUnmountDescriptor(rootDescriptor, expected: wrong)
            fatalError("不同挂载实例不得通过")
        } catch let error as HelperFailure { check(error.message.contains("不是已核验"), "实例不符必须拒绝") }

        // 匿名连接真实传递 NSFileHandle，不注册后台服务，不调用生产卸载方法。
        let receiver = HandleReceiver(expected: root, senderDescriptor: rootDescriptor)
        let delegate = HandleListener(receiver)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = handleTestInterface()
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let reply = TransferReply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish($0.localizedDescription) } as! PrivilegedMountProtocol
        proxy.unmount("仅测试传输", handle: rootHandle) { reply.finish($0) }
        check(reply.semaphore.wait(timeout: .now() + 10) == .success, "句柄传输必须收到回复")
        check(reply.error == nil, "句柄传输失败：\(reply.error ?? "")")
        check(fcntl(rootDescriptor, F_GETFL) >= 0, "接收端关闭副本不得关闭应用原始句柄")
        try PrivilegedMountEngine.validateUnmountDescriptor(rootDescriptor, expected: root)
        count += 1
        let arrayReply = TransferReply()
        let arrayProxy = connection.remoteObjectProxyWithErrorHandler { arrayReply.finish($0.localizedDescription) } as! PrivilegedMountProtocol
        arrayProxy.prepareEject(Data("仅测试数组传输".utf8), handles: [rootHandle]) { arrayReply.finish($0) }
        check(arrayReply.semaphore.wait(timeout: .now() + 10) == .success, "句柄数组传输必须收到回复")
        check(arrayReply.error == nil, "句柄数组传输失败：\(arrayReply.error ?? "")")
        check(fcntl(rootDescriptor, F_GETFL) >= 0, "数组接收端关闭副本不得关闭原始句柄")
        try PrivilegedMountEngine.validateUnmountDescriptor(rootDescriptor, expected: root)
        count += 1
        withExtendedLifetime(delegate) {}
        let report: [String: Any] = ["结果": "通过", "数量": count,
            "范围": "真实匿名NSXPC文件句柄及数组传输、异步强持有、独立关闭、目录/根路径/实例/事件标志拒绝；未注册服务、未同步或卸载文件系统、未操作设备。"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/build/helper-candidate/句柄传输验证结果.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
