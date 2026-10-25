import Foundation
import Darwin

// 不创建磁盘映像、不枚举设备、不提交卸载或弹出；只验证生产纯策略与普通文件描述符。
@main enum PrivilegedHelperEjectTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, "失败：\(message)")
            count += 1
        }
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("失败：\(name)应被拒绝") }
            catch { count += 1 }
        }
        func request(device: String = "disk9999s1", whole: String = "disk9999",
                     mediaID: UInt64 = 999_991, wholeID: UInt64 = 999_990,
                     bytes: Int64 = 1_000_000, wholeBytes: Int64 = 2_000_000) -> PrivilegedEjectRequest {
            PrivilegedEjectRequest(deviceID: device, wholeDiskID: whole,
                mediaRegistryID: mediaID, wholeMediaRegistryID: wholeID,
                mediaByteCount: bytes, wholeMediaByteCount: wholeBytes)
        }
        try HelperEjectPolicy.validate(request(), userID: 501)
        count += 1
        try HelperEjectPolicy.validate(request(device: "disk9999", mediaID: 999_990,
            bytes: 2_000_000), userID: 502)
        count += 1
        for userID: UInt32 in [0, 500, UInt32.max] {
            rejected("无效调用用户") { try HelperEjectPolicy.validate(request(), userID: userID) }
        }
        for item in [request(device: "/dev/disk9999s1"), request(device: "disk9999;echo x"),
                     request(device: "disk9998s1"), request(whole: "disk9999s1"),
                     request(whole: "../disk9999"), request(mediaID: 0), request(wholeID: 0),
                     request(bytes: 0), request(bytes: -1), request(wholeBytes: 0),
                     request(wholeBytes: 999_999)] {
            rejected("非法设备、身份或容量") { try HelperEjectPolicy.validate(item, userID: 501) }
        }
        func mount(path: String = "/Volumes/公开测试卷", owner: UInt32 = 501,
                   type: String = "ufsd_NTFS") -> MountedFileSystem {
            MountedFileSystem(type: type, source: "/dev/disk9999s1", mountPoint: path,
                identity: "构造的实例", ownerID: owner, isReadOnly: false)
        }
        for owner: UInt32 in [0, 501] {
            try HelperEjectPolicy.validateMount(mount(owner: owner), userID: 501)
            count += 1
        }
        for item in [mount(owner: 502), mount(path: "/"), mount(path: "/System/Volumes/Data"),
                     mount(path: "/Volumes"), mount(path: "/Volumes/../系统"),
                     mount(path: "/Volumes/./卷"), mount(path: "/Volumes-other/卷"),
                     mount(type: "blntfs")] {
            rejected("受保护、其他用户或尚未卸载的本驱动卷") {
                try HelperEjectPolicy.validateMount(item, userID: 501)
            }
        }
        rejected("无效描述符") { try HelperEject.validateDescriptor(-1, major: 1, minor: 0) }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("writeflow-eject-policy-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        check(descriptor >= 0, "只创建独立普通测试文件")
        defer {
            close(descriptor)
            precondition(unlink(temporary.path) == 0, "仅删除本次明确的普通测试文件")
        }
        rejected("普通文件不能冒充原整盘字符设备") {
            try HelperEject.validateDescriptor(descriptor, major: 1, minor: 0)
        }
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        check(null >= 0, "仅打开空设备检查类型边界，不执行ioctl")
        defer { close(null) }
        rejected("其他字符设备不匹配原盘设备号") {
            try HelperEject.validateDescriptor(null, major: UInt32.max, minor: UInt32.max)
        }
        check(try HelperEject.validateHandles([], mounts: []).isEmpty, "无挂载只接受空句柄数组")
        guard let root = MountedFileSystemReader.read(path: "/") else { fatalError("无法读取根挂载元数据") }
        let rootFD = open("/", O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        check(rootFD >= 0, "只打开根目录事件句柄，不同步或卸载")
        let rootHandle = FileHandle(fileDescriptor: rootFD, closeOnDealloc: true)
        defer { try? rootHandle.close() }
        let matched = try HelperEject.validateHandles([rootHandle], mounts: [root])
        check(matched.count == 1 && matched[0].1 == root, "数组精确匹配真实挂载元数据与根描述符")
        rejected("缺少分卷句柄") { _ = try HelperEject.validateHandles([], mounts: [root]) }
        rejected("多余分卷句柄") { _ = try HelperEject.validateHandles([rootHandle], mounts: []) }
        rejected("重复挂载实例") { _ = try HelperEject.validateHandles([rootHandle, rootHandle], mounts: [root, root]) }
        let wrong = MountedFileSystem(type: root.type, source: root.source, mountPoint: root.mountPoint,
            identity: "错误挂载实例", ownerID: root.ownerID, isReadOnly: root.isReadOnly)
        rejected("重复句柄不能满足不同分卷") {
            _ = try HelperEject.validateHandles([rootHandle, rootHandle], mounts: [root, wrong])
        }
        rejected("旧挂载实例") { _ = try HelperEject.validateHandles([rootHandle], mounts: [wrong]) }
        let engine = PrivilegedMountEngine()
        rejected("超大请求在设备访问前拒绝") {
            try engine.prepareEject(Data(repeating: 0, count: 4097), handles: [], userID: 501)
        }
        rejected("非法JSON在设备访问前拒绝") {
            try engine.prepareEject(Data("{无效请求}".utf8), handles: [], userID: 501)
        }
        rejected("非法身份在设备访问前拒绝") {
            try engine.prepareEject(JSONEncoder().encode(request(mediaID: 0)), handles: [], userID: 501)
        }
        do {
            var events: [String] = []
            try HelperEjectPolicy.ejectWithBusyRetry(validate: { events.append("核验") },
                attempt: { events.append("尝试"); return 0 }, wait: { events.append("等待") })
            check(events == ["核验", "尝试"], "立即成功时不等待或重复操作")
        }
        do {
            var events: [String] = [], attempts = 0
            try HelperEjectPolicy.ejectWithBusyRetry(validate: { events.append("核验") },
                attempt: { events.append("尝试"); attempts += 1; return attempts == 1 ? EBUSY : 0 },
                wait: { events.append("等待") })
            check(events == ["核验", "尝试", "等待", "核验", "尝试"],
                  "短暂占用只在重新核验后重试")
        }
        do {
            var attempts = 0, waits = 0, message: String?
            do {
                try HelperEjectPolicy.ejectWithBusyRetry(validate: {},
                    attempt: { attempts += 1; return EIO }, wait: { waits += 1 })
            } catch { message = error.localizedDescription }
            check(attempts == 1 && waits == 0 && message?.contains("（\(EIO)）") == true,
                  "非占用错误立即返回，不重试或吞掉原errno")
        }
        do {
            var attempts = 0, waits = 0, validations = 0, message: String?
            do {
                try HelperEjectPolicy.ejectWithBusyRetry(validate: { validations += 1 },
                    attempt: { attempts += 1; return EBUSY }, wait: { waits += 1 })
            } catch { message = error.localizedDescription }
            check(attempts == 31 && waits == 30 && validations == 31 && message?.contains("（\(EBUSY)）") == true,
                  "持续占用有严格次数边界，所有尝试前均重新核验")
        }
        do {
            var attempts = 0, waits = 0, validations = 0, message: String?
            do {
                try HelperEjectPolicy.ejectWithBusyRetry(validate: {
                    validations += 1
                    if validations == 2 { throw HelperFailure(message: "测试介质身份已变化") }
                }, attempt: { attempts += 1; return EBUSY }, wait: { waits += 1 })
            } catch { message = error.localizedDescription }
            check(attempts == 1 && waits == 1 && validations == 2 && message == "测试介质身份已变化",
                  "重试前身份变化时停止，不再提交弹出")
        }
        check(HelperEjectPolicy.permitsConnectedFixedMedia(location: "External", ejectable: false,
            removable: false, openStates: [false, false]), "明确固定外部盘且所有介质关闭允许连接态回执")
        for location: String? in [nil, "Internal", "File"] {
            check(!HelperEjectPolicy.permitsConnectedFixedMedia(location: location, ejectable: false,
                removable: false, openStates: [false]), "未知内部或镜像不接受固定盘后置分支")
        }
        for flags: (Bool?, Bool?) in [(nil, false), (false, nil), (true, false), (false, true)] {
            check(!HelperEjectPolicy.permitsConnectedFixedMedia(location: "External", ejectable: flags.0,
                removable: flags.1, openStates: [false]), "可弹出可移除或未知属性不能放宽消失条件")
        }
        for states: [Bool?] in [[], [nil], [false, nil], [false, true], [true, false]] {
            check(!HelperEjectPolicy.permitsConnectedFixedMedia(location: "External", ejectable: false,
                removable: false, openStates: states), "任何同盘介质打开或未知状态拒绝连接态回执")
        }
        print("通过：\(count) 项管理员弹出请求、挂载保护及描述符边界；未请求任何磁盘卸载或弹出。")
    }
}
