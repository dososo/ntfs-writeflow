import Foundation
import FSKit

@main
struct LegacyDeactivation {
    final class Counter { var cleanups = 0; var status: FSContainerStatus? }
    static let rw = ["rw,writeflow-media-id=9"]
    static var checks = 0

    static func check(_ result: Bool, _ message: String) {
        precondition(result, message); checks += 1
    }

    static func backend(_ image: String, _ writable: Bool, _ counter: Counter) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let p = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: p, retain: nil, cleanup: { counter.cleanups += 1 }, writable: writable)
    }

    static func volume(_ image: String, _ counter: Counter, legacy: Bool = true) throws -> ntfs3gVolume {
        let policy: ([String]) throws -> Bool = { try !ntfs3gFileSystem.resolvedMountReadOnly($0, resourceWritable: true) }
        let version = OperatingSystemVersion(majorVersion: legacy ? 15 : 26, minorVersion: legacy ? 4 : 0, patchVersion: 0)
        return try ntfs3gFileSystem.volumeType(on: version).init(backend: backend(image, false, counter),
            mountBackend: { options, _, source in
                try ntfs3gFileSystem.backendForMount(readOnly: !policy(options), source: source,
                    validateIdentity: {}, makeBackend: { try backend(image, $0, counter) })
            }, onContainerStatusChange: { counter.status = $0 }, legacyOpenUnlink: true,
            legacyActivationPolicy: legacy ? policy : nil)
    }

    static func rejects(_ code: Int32, _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("应拒绝：\(code)") }
        catch { check((error as NSError).code == Int(code), "必须保留原错误：\(error)") }
    }

    static func calls(_ sync: Int32, _ close: Int32, _ message: String) {
        check(nfsk_test_sync_calls() == sync && nfsk_test_close_calls() == close, message)
    }

    static func mounted(_ image: String, _ counter: Counter, legacy: Bool = true) throws -> (ntfs3gVolume, FSItem) {
        let v = try volume(image, counter, legacy: legacy)
        let root = try v.activate(taskOptions: rw)
        try v.mountVolume()
        return (v, root)
    }

    static func main() async throws {
        check(CommandLine.arguments.count == 2, "仅接受测试自建普通文件")
        let image = CommandLine.arguments[1]
        let c = Counter(); let (v, root) = try mounted(image, c)
        let (file, _) = try await v.createItem(named: FSFileName(string: "停用复读.txt"), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let payload = Data("旧系统收尾后保留只读可重激活".utf8)
        _ = try await v.write(contents: payload, to: file, at: 0)
        try await v.setXattr(named: FSFileName(string: "com.blteam.close-proof"), to: payload, on: file, policy: .alwaysSet)
        nfsk_test_reset_calls()
        // 实际15.4序列：系统已卸载，未回调unmount，直接deactivate。
        try await v.deactivate()
        calls(1, 1, "漏unmount时必须同步并恰一次消费RW句柄")
        check(c.status?.state == .ready, "成功才回ready")
        let roRoot = try v.activate(taskOptions: ["ro"])
        let (reopened, _) = try await v.lookupItem(named: FSFileName(string: "停用复读.txt"), inDirectory: roRoot)
        let attrs = try await v.attributes(FSItem.GetAttributesRequest(), of: reopened)
        check(attrs.size == payload.count, "同实例可重新激活RO读取文件元数据；内容另由ntfscat独立复读")
        let value = try await v.xattr(named: FSFileName(string: "com.blteam.close-proof"), of: reopened)
        check(value == payload, "同实例RO重激活读回真实xattr数据")
        nfsk_test_reset_calls(); try await v.deactivate(); try await v.deactivate()
        calls(0, 0, "RO激活后停用及重复停用不重复清理IO")
        let rootAgain = try v.activate(taskOptions: rw); try v.mountVolume()
        _ = try await v.createItem(named: FSFileName(string: "再次写入"), type: .directory,
            inDirectory: rootAgain, attributes: FSItem.SetAttributesRequest())
        await v.unmount(); nfsk_test_reset_calls(); try await v.deactivate()
        calls(0, 0, "正常unmount后deactivate不得重复IO")
        v.teardown(); check(c.cleanups == 3, "重复激活后每个包装器只释放一次")

        let queryCounter = Counter(); let queryBackend = try backend(image, true, queryCounter)
        var queryError: Int32 = 0
        guard let queryHandle = nfsk_mount(queryBackend.backend, false, &queryError) else { throw posixError(queryError) }
        check(nfsk_has_open_items(queryHandle) == 0 && nfsk_has_open_nonroot_items(queryHandle) == 0, "空登记两查询均为0")
        check(nfsk_open_item(queryHandle, NFSK_ROOT_INO) == 0, "真实C根项登记成功")
        check(nfsk_has_open_items(queryHandle) == 1 && nfsk_has_open_nonroot_items(queryHandle) == 0, "通用查询保根语义，仅新查询排根")
        let queryFile = nfsk_lookup(queryHandle, NFSK_ROOT_INO, "停用复读.txt", &queryError)
        check(queryFile != 0 && queryError == 0 && nfsk_open_item(queryHandle, queryFile) == 0, "真实C非根文件登记成功")
        check(nfsk_has_open_items(queryHandle) == 1 && nfsk_has_open_nonroot_items(queryHandle) == 1, "根与非根并存仍报告非根忙")
        check(nfsk_close_item(queryHandle, queryFile) == 0 && nfsk_has_open_nonroot_items(queryHandle) == 0
            && nfsk_has_open_items(queryHandle) == 1, "关闭非根不偷偷清除根登记")
        check(nfsk_close_item(queryHandle, NFSK_ROOT_INO) == 0 && nfsk_has_open_items(queryHandle) == 0, "通用最终close根仍正常")
        check(nfsk_has_open_nonroot_items(nil) == -EINVAL, "新查询无卷时不能伪造无占用")
        check(nfsk_umount(queryHandle) == 0, "查询测试正常收尾")
        nfsk_backend_free(queryBackend.backend); queryBackend.cleanup()

        let cached = Counter(); let (cachedVolume, cachedRoot) = try mounted(image, cached)
        // 15.4保留根项到deactivate；普通用户FD已由kernel正常卸载门槛确认不再占用。
        try await cachedVolume.openItem(cachedRoot, modes: [.read])
        nfsk_test_reset_calls()
        try await cachedVolume.synchronize(flags: .wait)
        try await cachedVolume.deactivate()
        calls(2, 1, "仅根缓存不应阻止helper同步后的旧系统正常收尾")
        check(cached.status?.state == .ready, "根缓存收尾成功才ready")
        let cachedRORoot = try cachedVolume.activate(taskOptions: ["ro"])
        let (cachedFile, _) = try await cachedVolume.lookupItem(named: FSFileName(string: "停用复读.txt"), inDirectory: cachedRORoot)
        let cachedValue = try await cachedVolume.xattr(named: FSFileName(string: "com.blteam.close-proof"), of: cachedFile)
        check(cachedValue == payload, "根缓存收尾后原数据仍可RO重激活读取")
        nfsk_test_reset_calls(); try await cachedVolume.deactivate(); calls(0, 0, "根缓存处理后RO停用不重复IO")
        cachedVolume.teardown(); check(cached.cleanups == 2, "根缓存收尾包装器仅释放一次")

        let busy = Counter(); let (b, br) = try mounted(image, busy)
        try await b.openItem(br, modes: [.read])
        let (bf, _) = try await b.lookupItem(named: FSFileName(string: "停用复读.txt"), inDirectory: br)
        try await b.openItem(bf, modes: [.read]); try await b.openItem(bf, modes: [.read])
        let busyBefore = try Data(contentsOf: URL(fileURLWithPath: image))
        nfsk_test_reset_calls(); await rejects(EBUSY) { try await b.deactivate() }
        check((try? Data(contentsOf: URL(fileURLWithPath: image))) == busyBefore, "忙拒绝不改变普通镜像字节")
        calls(0, 0, "真实打开登记阻止停用且不抢先sync/close")
        try await b.closeItem(bf, modes: [.read])
        await rejects(EBUSY) { try await b.deactivate() }
        try await b.closeItem(bf, modes: [])
        try await b.deactivate(); calls(1, 1, "最终close后才允许正常停用")
        b.teardown()

        let force = Counter(); let (f, forceRoot) = try mounted(image, force)
        try await f.openItem(forceRoot, modes: [.read])
        let forceBefore = try Data(contentsOf: URL(fileURLWithPath: image))
        nfsk_test_reset_calls(); await rejects(EBUSY) { try await f.deactivate(options: [.force]) }
        check((try? Data(contentsOf: URL(fileURLWithPath: image))) == forceBefore, "force拒绝不改变普通镜像字节")
        calls(0, 0, "force不得强制关闭")
        try await f.deactivate(); f.teardown()

        let modern = Counter(); let (m, _) = try mounted(image, modern, legacy: false)
        nfsk_test_reset_calls(); await rejects(EBUSY) { try await m.deactivate() }
        calls(0, 0, "现代停用保留原noIO顺序")
        await m.unmount(); nfsk_test_reset_calls(); try await m.deactivate(); calls(0, 0, "现代正常停用不新增IO")
        m.teardown()

        for closeFailure in [false, true] {
            let count = Counter(); let (failed, _) = try mounted(image, count)
            nfsk_test_reset_calls()
            if closeFailure { nfsk_test_fail_close(1) } else { nfsk_test_fail_sync(1) }
            await rejects(EIO) { try await failed.deactivate() }
            nfsk_test_fail_sync(0); nfsk_test_fail_close(0)
            check(count.status?.state == .notReady, "收尾错误不得ready")
            calls(1, 1, "失败路径同步一次并消费关闭一次，不重复关闭句柄")
            let s = nfsk_test_sync_calls(), u = nfsk_test_close_calls()
            await rejects(EIO) { try await failed.deactivate() }
            calls(s, u, "重复停用保原错且不重复关闭")
            check(count.cleanups == 2, "失败精确释放旧RO及RW包装器")
            failed.teardown(); check(count.cleanups == 2, "销毁不重复cleanup")
        }
        print("旧系统停用回归通过：\(checks)项；真实普通文件引擎，不代表目标系统VFS。")
    }
}
