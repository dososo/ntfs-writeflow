import Foundation
import Darwin

@main enum ManagedUnmountTests {
    static func main() throws {
        var passed: [String] = []
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            passed.append(name)
        }
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError(name) }
            catch is HelperFailure { passed.append(name) }
            catch { fatalError("出现非预期错误：\(error)") }
        }
        let token = UUID().uuidString
        let request = PrivilegedMountRequest(deviceID: "disk9999s1", mediaRegistryID: 123,
            wholeMediaRegistryID: 122, mediaByteCount: 134_217_728, readOnly: false)
        let ticket = HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: "1:2")
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        func mounted(path: String? = nil, identity: String = "1:2", source: String = "/dev/disk9999s1",
                     owner: UInt32 = 0, readOnly: Bool = false) -> MountedFileSystem {
            MountedFileSystem(type: "blntfs", source: source, mountPoint: path ?? (PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"),
                identity: identity, ownerID: owner, isReadOnly: readOnly)
        }
        let expected = mounted()
        try ManagedUnmount.verifyMount(ticket: ticket, expected: expected)
        check(true, "仅接受当前凭据对应的系统自有挂载")
        let legacy = MountedFileSystem(type: "macfuse", source: expected.source, mountPoint: path,
            identity: expected.identity, ownerID: 0, isReadOnly: false)
        try ManagedUnmount.verifyMount(ticket: ticket, expected: legacy)
        check(true, "旧后端标识仅在相同来源及凭据下放行")
        for (type, source) in [("blntfs-legacy", expected.source), ("macfuse", "/dev/disk8888s1")] {
            rejected("拒绝通用FUSE标识或旧后端错误来源") {
                try ManagedUnmount.verifyMount(ticket: ticket, expected: MountedFileSystem(type: type,
                    source: source, mountPoint: path, identity: expected.identity, ownerID: 0, isReadOnly: false))
            }
        }
        for invalid in [MountedFileSystem(type: "macfuse", source: expected.source, mountPoint: "/Volumes/普通FUSE卷",
                identity: expected.identity, ownerID: 0, isReadOnly: false),
                MountedFileSystem(type: "macfuse", source: expected.source, mountPoint: path,
                identity: expected.identity, ownerID: 501, isReadOnly: false)] {
            rejected("默认macfuse类型不放宽外部路径或非root挂载") {
                try ManagedUnmount.verifyMount(ticket: ticket, expected: invalid)
            }
        }
        for invalid in [mounted(path: "/Volumes/测试卷"), mounted(path: "/private/tmp/ntfs-writeflow-501/\(token)"),
                        mounted(path: PrivilegedMountConfiguration.namespace + "/502/\(token)/volume"),
                        mounted(path: PrivilegedMountConfiguration.namespace + "/501/\(UUID().uuidString)/volume"),
                        mounted(identity: "3:4"), mounted(source: "/dev/disk9999s2"), mounted(owner: 501)] {
            rejected("拒绝外部目录、其他用户、旧凭据或错误挂载身份") {
                try ManagedUnmount.verifyMount(ticket: ticket, expected: invalid)
            }
        }
        let noIdentity = HelperTicket(userID: 501, token: token, request: request)
        rejected("缺少已保存挂载实例不能取得旧系统卸载资格") {
            try ManagedUnmount.verifyMount(ticket: noIdentity, expected: expected)
        }
        try HelperNamespace.UnmountLease.verifyTicket(ticket, expected: ticket)
        check(true, "原票据与介质请求完整匹配")
        for changed in [
            HelperTicket(userID: 502, token: token, request: request, fileSystemIdentity: "1:2"),
            HelperTicket(userID: 501, token: UUID().uuidString, request: request, fileSystemIdentity: "1:2"),
            HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: "3:4"),
            HelperTicket(userID: 501, token: token, request: PrivilegedMountRequest(deviceID: "disk9999s1",
                mediaRegistryID: 124, wholeMediaRegistryID: 122, mediaByteCount: 134_217_728, readOnly: false), fileSystemIdentity: "1:2"),
            HelperTicket(userID: 501, token: token, request: PrivilegedMountRequest(deviceID: "disk9999s1",
                mediaRegistryID: 123, wholeMediaRegistryID: 125, mediaByteCount: 134_217_728, readOnly: false), fileSystemIdentity: "1:2")
        ] {
            rejected("票据替换用户、旧token、FSID复用或IOMedia登记变化均拒绝") {
                try HelperNamespace.UnmountLease.verifyTicket(changed, expected: ticket)
            }
        }
        var metadata = stat()
        metadata.st_mode = S_IFDIR | 0o755
        metadata.st_uid = 0
        try HelperNamespace.verifyDirectoryStatus(metadata, permissions: 0o755)
        check(true, "构造root目录元数据符合固定模式；不冒充真实root验收")
        metadata.st_mode = S_IFDIR | 0o1700
        rejected("缓存目录必须为精确0700，不接受额外特殊权限位") {
            try HelperNamespace.verifyDirectoryStatus(metadata, permissions: 0o700)
        }
        for (owner, mode): (UInt32, mode_t) in [(501, S_IFDIR | 0o755), (0, S_IFDIR | 0o777),
                                               (0, S_IFREG | 0o755), (0, S_IFDIR | 0o700)] {
            metadata.st_uid = owner
            metadata.st_mode = mode
            rejected("拒绝非root、可写、非目录或模式变化的父目录元数据") {
                try HelperNamespace.verifyDirectoryStatus(metadata, permissions: 0o755)
            }
        }

        let temporary = "/private/tmp/WriteFlow-卸载验证-\(token)"
        precondition(mkdir(temporary, 0o700) == 0)
        let descriptor = open(temporary, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(descriptor >= 0)
        defer { close(descriptor); precondition(rmdir(temporary) == 0) }
        try ManagedUnmount.verifyDescriptor(descriptor, path: temporary)
        check(true, "真实普通目录事件FD及精确路径验证通过")
        rejected("真实FD不能冒充另一挂载路径") { try ManagedUnmount.verifyDescriptor(descriptor, path: path) }
        let readable = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(readable >= 0)
        defer { close(readable) }
        rejected("普通目录读取FD不能代替事件FD") { try ManagedUnmount.verifyDescriptor(readable, path: temporary) }
        let secondReader = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(secondReader >= 0)
        defer { close(secondReader) }
        check(flock(readable, LOCK_EX | LOCK_NB) == 0, "真实普通目录可取得非阻塞排他租约")
        check(flock(secondReader, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK,
              "独立打开的同目录FD不能并发取得租约")
        precondition(flock(readable, LOCK_UN) == 0)
        check(flock(secondReader, LOCK_EX | LOCK_NB) == 0, "释放后另一目录FD才能取得租约")
        precondition(flock(secondReader, LOCK_UN) == 0)
        let wholeLockName = try HelperNamespace.mediaLockName(for: request)
        let otherPartition = PrivilegedMountRequest(deviceID: "disk9999s2", mediaRegistryID: 124,
            wholeMediaRegistryID: 122, mediaByteCount: 134_217_728, readOnly: false)
        let otherLockName = try HelperNamespace.mediaLockName(for: otherPartition)
        check(wholeLockName == "122.lock" && otherLockName == wholeLockName,
              "同整盘的不同分区必须共用wholeMediaRegistryID锁")
        let mediaLock = temporary + "/" + wholeLockName
        let mediaFD = open(mediaLock, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        precondition(mediaFD >= 0 && flock(mediaFD, LOCK_EX | LOCK_NB) == 0)
        let mediaHandle = FileHandle(fileDescriptor: mediaFD, closeOnDealloc: true)
        let contender = open(mediaLock, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        precondition(contender >= 0)
        defer { try? mediaHandle.close(); close(contender); precondition(unlink(mediaLock) == 0) }
        let child = Process(), inputPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = inputPipe; child.standardOutput = mediaHandle; child.standardError = FileHandle.nullDevice
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        try mediaHandle.close()
        check(flock(contender, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK,
              "真实子进程继承FD1后，父关闭锁FD仍不能重获媒体租约")
        try inputPipe.fileHandleForWriting.close()
        child.waitUntilExit()
        check(child.terminationStatus == 0 && flock(contender, LOCK_EX | LOCK_NB) == 0,
              "真实子进程结束关闭继承FD后，下一代才能重获锁")
        precondition(flock(contender, LOCK_UN) == 0)
        var mediaStatus = stat()
        mediaStatus.st_uid = 0; mediaStatus.st_mode = S_IFREG | 0o600; mediaStatus.st_nlink = 1
        try HelperNamespace.verifyMediaLockMetadata(mediaStatus)
        check(true, "构造root单链接0600媒体锁元数据通过；不冒充root创建验收")
        for (owner, mode, links): (UInt32, mode_t, UInt16) in [(501, S_IFREG | 0o600, 1),
                (0, S_IFREG | 0o644, 1), (0, S_IFREG | 0o600, 2), (0, S_IFDIR | 0o600, 1)] {
            mediaStatus.st_uid = owner; mediaStatus.st_mode = mode; mediaStatus.st_nlink = links
            rejected("媒体锁所有权、模式、链接数或文件类型异常均拒绝") {
                try HelperNamespace.verifyMediaLockMetadata(mediaStatus)
            }
        }
        rejected("无效FD在任何卸载前拒绝") { try ManagedUnmount.verifyDescriptor(-1, path: temporary) }
        let inheritable = dup(descriptor)
        precondition(inheritable >= 0)
        defer { close(inheritable) }
        rejected("未设置CLOEXEC的事件FD不能接受") { try ManagedUnmount.verifyDescriptor(inheritable, path: temporary) }
        let filePath = temporary + "/普通文件"
        let file = open(filePath, O_CREAT | O_EXCL | O_EVTONLY | O_CLOEXEC, 0o600)
        precondition(file >= 0)
        defer { close(file); precondition(unlink(filePath) == 0) }
        rejected("真实普通文件事件FD不能冒充挂载根目录") { try ManagedUnmount.verifyDescriptor(file, path: filePath) }
        try HelperNamespace.setACL(descriptor, allowedUser: nil)
        try HelperNamespace.verifyACL(descriptor, allowedUser: nil)
        check(true, "真实普通目录空ACL设置与回读；非root租约未实测")

        func simulatedRootStatus(_ fd: Int32) throws -> stat {
            var status = stat()
            guard fstat(fd, &status) == 0 else { throw HelperFailure(message: "测试读取元数据失败") }
            status.st_uid = 0
            return status
        }
        let runtimePath = temporary + "/runtime"
        let libraryPath = runtimePath + "/libfuse.2.dylib"
        let unknownPath = runtimePath + "/未知缓存"
        let linkedPath = temporary + "/缓存硬链接"
        let ticketPath = temporary + "/ticket.json"
        func createFile(_ name: String) {
            let fd = open(name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            precondition(fd >= 0)
            close(fd)
        }
        createFile(ticketPath)
        defer { precondition(unlink(ticketPath) == 0) }
        try HelperNamespace.removeRuntime(parent: readable)
        check(access(ticketPath, F_OK) == 0, "不存在运行时缓存时保留旧流程与票据")
        precondition(mkdir(runtimePath, 0o700) == 0)
        createFile(libraryPath)
        createFile(unknownPath)
        rejected("未知缓存项在删除任何已知文件之前拒绝") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        check(access(libraryPath, F_OK) == 0 && access(unknownPath, F_OK) == 0 && access(ticketPath, F_OK) == 0,
              "未知缓存保留已知文件、未知文件和票据")
        precondition(unlink(unknownPath) == 0)
        rejected("真实非root目录不能被当作root缓存清理") { try HelperNamespace.removeRuntime(parent: readable) }
        precondition(chmod(libraryPath, 0o400) == 0)
        rejected("缓存leaf模式400不能清理") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        precondition(chmod(libraryPath, 0o600) == 0)
        precondition(link(libraryPath, linkedPath) == 0)
        rejected("缓存leaf有第二个硬链接时不能删除") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        precondition(unlink(linkedPath) == 0)
        rejected("缓存leaf不是root所有时不能删除") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: { fd in
                var status = try simulatedRootStatus(fd)
                if status.st_mode & S_IFMT == S_IFREG { status.st_uid = 501 }
                return status
            })
        }
        precondition(chmod(runtimePath, 0o755) == 0)
        rejected("运行时目录不是0700时不能清理") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        precondition(chmod(runtimePath, 0o700) == 0)
        let runtimeFD = open(runtimePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let libraryFD = open(libraryPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        precondition(runtimeFD >= 0 && libraryFD >= 0)
        try HelperNamespace.setACL(runtimeFD, allowedUser: geteuid())
        rejected("运行时目录包含额外ACL时不清理") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        try HelperNamespace.setACL(runtimeFD, allowedUser: nil)
        try HelperNamespace.setACL(libraryFD, allowedUser: geteuid())
        rejected("缓存leaf包含额外ACL时不清理") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        try HelperNamespace.setACL(libraryFD, allowedUser: nil)
        close(libraryFD); close(runtimeFD)
        try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        check(access(runtimePath, F_OK) != 0 && access(ticketPath, F_OK) == 0,
              "模拟root元数据下仅删除已知600缓存及空目录，不删除票据")
        precondition(mkdir(runtimePath, 0o700) == 0)
        precondition(symlink(filePath, libraryPath) == 0)
        rejected("已知缓存名为符号链接时不跟随或删除目标") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        check(access(filePath, F_OK) == 0, "符号链接外的原文件保持存在")
        precondition(unlink(libraryPath) == 0)
        createFile(libraryPath)
        precondition(chmod(libraryPath, 0o500) == 0)
        try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        check(access(runtimePath, F_OK) != 0, "模拟root元数据下允许500缓存逐个清理")
        precondition(mkdir(runtimePath, 0o700) == 0 && mkdir(libraryPath, 0o700) == 0)
        rejected("缓存leaf为目录时不当作普通文件删除") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        precondition(rmdir(libraryPath) == 0)
        try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        check(access(runtimePath, F_OK) != 0, "已知缓存不存在时只移除通过核验的空runtime目录")
        let executablePath = runtimePath + "/NTFSWriteFlowLegacy"
        precondition(mkdir(runtimePath, 0o700) == 0)
        createFile(libraryPath); createFile(executablePath)
        do { try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus) }
        catch {
            precondition(unlink(libraryPath) == 0)
            precondition(unlink(executablePath) == 0)
            precondition(rmdir(runtimePath) == 0)
            throw error
        }
        check(access(runtimePath, F_OK) != 0, "两个固定缓存均可逐个安全清理")
        precondition(mkdir(runtimePath, 0o700) == 0)
        createFile(libraryPath); createFile(executablePath)
        precondition(chmod(libraryPath, 0o400) == 0)
        rejected("任一缓存异常时，另一有效缓存也不能提前删除") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        check(access(libraryPath, F_OK) == 0 && access(executablePath, F_OK) == 0 && access(ticketPath, F_OK) == 0,
              "两个缓存完整预检失败时，全部缓存和票据均保留")
        precondition(chmod(libraryPath, 0o600) == 0)
        try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)

        let helperPath = runtimePath + "/NTFSWriteFlowMountHelper"
        precondition(mkdir(runtimePath, 0o700) == 0)
        createFile(helperPath); createFile(libraryPath); createFile(executablePath)
        precondition(chmod(helperPath, 0o400) == 0)
        rejected("新助手副本异常时，三个固定缓存均须保留") {
            try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus)
        }
        check(access(helperPath, F_OK) == 0 && access(libraryPath, F_OK) == 0 && access(executablePath, F_OK) == 0,
              "完整核验助手、库和旧前端后才允许任何删除")
        precondition(chmod(helperPath, 0o500) == 0)
        do { try HelperNamespace.removeRuntime(parent: readable, inspect: simulatedRootStatus) }
        catch {
            precondition(unlink(libraryPath) == 0 && unlink(executablePath) == 0)
            precondition(unlink(helperPath) == 0 && rmdir(runtimePath) == 0)
            throw error
        }
        check(access(runtimePath, F_OK) != 0 && access(ticketPath, F_OK) == 0,
              "模拟root元数据下清理固定助手副本，不删除票据")

        var calls: [String] = []
        var currentFD: MountedFileSystem? = expected
        var currentPath: MountedFileSystem? = expected
        var synchronizeError: Int32 = 0
        var unmountError: Int32 = 0
        var leaseValid = true
        var mediaValid = true
        var changeOnSync: (() -> Void)?
        let operations = ManagedUnmount.Operations(
            verifyDescriptor: { fd, value in
                precondition(fd == descriptor && value == path, "模拟系统调用保持原事件FD和固定路径")
            },
            readDescriptor: { _ in currentFD }, readPath: { _ in currentPath },
            synchronize: { _ in calls.append("同步"); changeOnSync?(); errno = synchronizeError; return synchronizeError == 0 ? 0 : -1 },
            unmountPath: { value, flags in
                precondition(value == path && flags == 0, "只能正常卸载固定路径，不得强制")
                calls.append("卸载"); errno = unmountError; return unmountError == 0 ? 0 : -1
            })
        func execute() throws {
            try ManagedUnmount.executeLegacy(descriptor: descriptor, expected: expected,
                validateLease: {
                    calls.append("租约")
                    guard leaseValid else { throw HelperFailure(message: "模拟父目录或凭据已变化") }
                }, validateMedia: {
                    calls.append("介质")
                    guard mediaValid else { throw HelperFailure(message: "模拟IOMedia身份已变化") }
                }, operations: operations)
        }
        try execute()
        check(calls == ["租约", "介质", "同步", "租约", "介质", "卸载"], "同步前后均复核租约及介质，最终仅正常卸载一次")
        calls = []; synchronizeError = EIO
        rejected("同步错误时不调用卸载") { try execute() }
        check(!calls.contains("卸载"), "同步错误保留挂载和凭据")
        synchronizeError = 0; calls = []; unmountError = EBUSY
        rejected("占用错误按原错误拒绝，不重试或强制") { try execute() }
        check(calls.filter { $0 == "卸载" }.count == 1, "EBUSY只提交一次正常卸载")
        unmountError = 0; calls = []; currentPath = mounted(source: "/dev/disk8888s1")
        rejected("FSID相同但来源不同不得卸载") { try execute() }
        check(!calls.contains("同步") && !calls.contains("卸载"), "路径与FD不一致在同步前停止")
        currentPath = expected; currentFD = mounted(identity: "7:8"); calls = []
        rejected("原FD实例已变化不得卸载") { try execute() }
        currentFD = expected; calls = []; leaseValid = false
        rejected("父目录或票据租约变化不得卸载") { try execute() }
        leaseValid = true; calls = []; mediaValid = false
        rejected("相同BSD名但IOMedia登记变化不得卸载") { try execute() }
        mediaValid = true; calls = []; changeOnSync = { currentPath = mounted(identity: "9:10") }
        rejected("同步后至卸载前路径变化必须拒绝") { try execute() }
        check(!calls.contains("卸载"), "同步后重新读取而非复用旧快照")
        currentPath = expected; calls = []; changeOnSync = { leaseValid = false }
        rejected("同步后租约撤销必须拒绝") { try execute() }
        currentPath = expected; currentFD = expected; leaseValid = true; calls = []
        changeOnSync = { currentFD = mounted(identity: "11:12") }
        rejected("同步后原FD实例变化必须拒绝") { try execute() }
        check(!calls.contains("卸载"), "同步后原FD变化不会调用路径卸载")
        currentFD = expected; calls = []; changeOnSync = { mediaValid = false }
        rejected("同步后介质登记变化必须拒绝") { try execute() }
        check(!calls.contains("卸载"), "同路径同FSID也不能覆盖介质身份失败")
        mediaValid = true
        leaseValid = true; changeOnSync = nil
        rejected("旧系统缺少保留父FD的租约时拒绝") {
            try ManagedUnmount.synchronizeAndUnmount(descriptor: descriptor, expected: expected,
                legacyLease: nil, validateMedia: {}, useLegacy: true)
        }
        if geteuid() != 0 {
            rejected("真实普通用户不能取得系统root目录租约") { _ = try HelperNamespace(userID: geteuid()) }
        }
        let report: [String: Any] = ["结果": "通过", "数量": passed.count, "检查": passed,
            "边界": "确定性模拟挂载与root元数据；真实自有普通文件/目录FD、ACL、flock和已知缓存清理。未执行同步、挂载、卸载、root助手或实体盘操作。非其他root绕过仲裁的防护证明。"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
