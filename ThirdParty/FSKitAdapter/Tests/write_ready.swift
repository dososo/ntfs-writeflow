import Foundation
import FSKit

@main
struct WriteReadyChecks {
    final class Trace {
        var factory = 0
        var cleanups = 0
        var checks = 0
        var failure: Int32 = 0
        var stale = false
        var staleAfterCapability = false
        var status: FSContainerStatus?
    }
    static let token = "11111111-2222-4333-8444-555555555555"
    static let other = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    static let media: UInt64 = 9_876_543_210
    static let prepare = "com.blteam.ntfsworkbench.write-prepare."
    static let ready = "com.blteam.ntfsworkbench.write-ready."
    static var rw: [String] { ["rw,writeflow-media-id=\(media),writeflow-ready-token=\(token)"] }

    static func backend(_ image: String, _ writable: Bool, _ trace: Trace) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let b = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: b, retain: nil, cleanup: { trace.cleanups += 1 }, writable: writable)
    }
    static func volume(_ image: String, _ trace: Trace, legacy: Bool = true, gate: Bool = true,
                       load: [String] = []) throws -> ntfs3gVolume {
        let identity = { if trace.stale { throw posixError(ESTALE) } }
        let policy: ([String]) throws -> Bool = { options in
            try identity()
            return try !ntfs3gFileSystem.resolvedMountReadOnly(legacy ? options : load + options, resourceWritable: true)
        }
        return try ntfs3gVolume(backend: backend(image, false, trace),
            mountBackend: { options, oldReadOnly, source in
                let readOnly = try !policy(options)
                guard readOnly != oldReadOnly else { return nil }
                return try ntfs3gFileSystem.backendForMount(readOnly: readOnly, source: source,
                    validateIdentity: identity, makeBackend: { writable in
                        trace.factory += 1
                        return try backend(image, writable, trace)
                    })
            }, onContainerStatusChange: { trace.status = $0 }, legacyOpenUnlink: true,
            legacyActivationPolicy: legacy ? policy : nil,
            legacyActivationOptions: load,
            validateWriteCapability: legacy && gate ? { options in
                guard !ntfs3gFileSystem.defaultsToReadOnly(options) else { return }
                try identity()
                trace.checks += 1
                if trace.failure != 0 { throw posixError(trace.failure) }
                if trace.staleAfterCapability { trace.stale = true }
            } : nil)
    }
    static func denied(_ code: Int32? = nil, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure("应拒绝操作") }
        catch { if let code { precondition((error as NSError).code == Int(code), "错误码不符：\(error)") } }
    }
    static func create(_ v: ntfs3gVolume, _ root: FSItem, _ name: String) async throws -> FSItem {
        try await v.createItem(named: FSFileName(string: name), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest()).0
    }
    static func receipt(_ bytes: Data) throws {
        precondition(bytes.count <= 1024)
        let value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        precondition(Set(value.keys) == ["schema", "token", "mediaID", "writable"])
        precondition(value["schema"] as? Int == 1 && value["token"] as? String == token)
        precondition((value["mediaID"] as? NSNumber)?.uint64Value == media && value["writable"] as? Bool == true)
    }
    static func main() async throws {
        let image = CommandLine.arguments[1]
        // 真实helper先fsync再正常unmount；不能跳过sync声称失败卷可清理。
        for reason in [NFSK_CHECK_DIRTY, NFSK_CHECK_HIBERNATED, NFSK_CHECK_JOURNAL, NFSK_CHECK_METADATA] {
            let trace = Trace(); let candidate = try volume(image, trace)
            let root = try candidate.activate(taskOptions: rw)
            let before = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
            nfsk_test_fail_preflight(Int32(reason))
            await denied(EIO) { _ = try await candidate.xattr(named: FSFileName(string: prepare + token), of: root) }
            nfsk_test_fail_preflight(0)
            try await candidate.synchronize(flags: .wait)
            _ = try await candidate.attributes(FSItem.GetAttributesRequest(), of: root)
            await denied(EIO) { _ = try await candidate.xattr(named: FSFileName(string: ready + token), of: root) }
            await denied(EIO) { _ = try await create(candidate, root, "预检失败不得写") }
            precondition(trace.factory == 0 && trace.cleanups == 0 && koio_trace_writable_mounts() == 0 && koio_trace_pwrites() == 0)
            await candidate.unmount(); try await candidate.deactivate(); candidate.teardown()
            precondition(trace.status?.state == .notReady && trace.cleanups == 1 && koio_trace_pwrites() == 0)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        print("四类预检拒绝：原RO可读，真实helper顺序sync→unmount→deactivate成功，原错不被RO成功清理覆盖，零RW工厂/零pwrite/raw不变")
        let identityTrace = Trace(); identityTrace.staleAfterCapability = true
        let identityVolume = try volume(image, identityTrace)
        let identityRoot = try identityVolume.activate(taskOptions: rw)
        let identityBefore = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
        await denied(ESTALE) { _ = try await identityVolume.xattr(named: FSFileName(string: prepare + token), of: identityRoot) }
        identityTrace.stale = false
        try await identityVolume.synchronize(flags: .wait)
        _ = try await identityVolume.attributes(FSItem.GetAttributesRequest(), of: identityRoot)
        await denied(ESTALE) { _ = try await identityVolume.xattr(named: FSFileName(string: ready + token), of: identityRoot) }
        precondition(identityTrace.factory == 0 && identityTrace.cleanups == 0 && identityTrace.checks == 1)
        await identityVolume.unmount(); try await identityVolume.deactivate(); identityVolume.teardown()
        precondition(identityTrace.cleanups == 1 && koio_trace_pwrites() == 0 && koio_trace_writable_mounts() == 0)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == identityBefore)
        print("同步能力后身份变化：完整准备仍在原RO存活时拒绝，helper顺序正常卸载、原ESTALE锁存、零写")
        for options in [["writeflow-ready-token=" + token], ["-o", "rw,writeflow-ready-token=" + token],
                        ["-owriteflow-ready-token=" + token, "writeflow-ready-token=" + token]] {
            let parsed = try ntfs3gFileSystem.writeReadyToken(options)
            precondition(parsed == token)
        }
        let loadInputs: [([String], [String])] = [(rw, []),
            (["rw,writeflow-ready-token=" + token], ["writeflow-media-id=\(media)"]),
            (["rw,writeflow-media-id=\(media)"], ["writeflow-ready-token=" + token])]
        for (index, inputs) in loadInputs.enumerated() {
        let loadTrace = Trace(); let loadVolume = try volume(image, loadTrace, load: inputs.0)
        let loadRoot = try loadVolume.activate(taskOptions: inputs.1)
        let loadBefore = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
        await denied(EROFS) { _ = try await create(loadVolume, loadRoot, "加载参数不得绕过握手") }
        try loadVolume.mountVolume()
        await denied(EAGAIN) { _ = try await loadVolume.xattr(named: FSFileName(string: ready + token), of: loadRoot) }
        precondition(loadTrace.factory == 0 && loadTrace.checks == 0 && koio_trace_pwrites() == 0)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == loadBefore)
        try receipt(try await loadVolume.xattr(named: FSFileName(string: prepare + token), of: loadRoot))
        _ = try await create(loadVolume, loadRoot, "完整加载上下文准备成功\(index)")
        try await loadVolume.synchronize(flags: .wait)
        await loadVolume.unmount(); try await loadVolume.deactivate(); loadVolume.teardown()
        precondition(loadTrace.factory == 1 && loadTrace.checks == 1 && loadTrace.cleanups == 2)
        }
        for activation in [["rw,writeflow-ready-token=" + other], ["rw,writeflow-media-id=10"],
                           ["rw,writeflow-ready-token=" + other.lowercased()]] {
            let t = Trace(); let v = try volume(image, t, load: rw)
            let before = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
            await denied(EINVAL) { _ = try v.activate(taskOptions: activation) }
            v.teardown()
            precondition(t.factory == 0 && t.checks == 0 && t.cleanups == 1 && koio_trace_pwrites() == 0)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        let staleTrace = Trace(); let stale = try volume(image, staleTrace, load: rw)
        let staleRoot = try stale.activate(taskOptions: [])
        let staleBefore = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
        staleTrace.stale = true
        await denied(ESTALE) { _ = try await stale.xattr(named: FSFileName(string: prepare + token), of: staleRoot) }
        staleTrace.stale = false
        await denied(ESTALE) { _ = try await stale.xattr(named: FSFileName(string: ready + token), of: staleRoot) }
        _ = try await stale.attributes(FSItem.GetAttributesRequest(), of: staleRoot)
        precondition(staleTrace.checks == 0 && staleTrace.factory == 0 && staleTrace.cleanups == 0,
            "身份错误必须在资源同步和关闭RO之前拒绝")
        try await stale.synchronize(flags: .wait); await stale.unmount(); try await stale.deactivate(); stale.teardown()
        precondition(staleTrace.cleanups == 1 && koio_trace_pwrites() == 0)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == staleBefore)
        let loadedROTrace = Trace(); let loadedRO = try volume(image, loadedROTrace, load: ["ro"])
        let loadedRORoot = try loadedRO.activate(taskOptions: rw)
        await denied { _ = try await loadedRO.xattr(named: FSFileName(string: prepare + token), of: loadedRORoot) }
        await denied(EROFS) { _ = try await create(loadedRO, loadedRORoot, "加载RO不得改为RW") }
        loadedRO.teardown(); precondition(loadedROTrace.factory == 0 && loadedROTrace.checks == 0)
        let modernLoadTrace = Trace(); let modernLoad = try volume(image, modernLoadTrace, legacy: false, load: rw)
        let modernLoadRoot = try modernLoad.activate(taskOptions: [])
        try modernLoad.mountVolume()
        _ = try await create(modernLoad, modernLoadRoot, "现代加载仍走原mount")
        await denied { _ = try await modernLoad.xattr(named: FSFileName(string: prepare + token), of: modernLoadRoot) }
        await modernLoad.unmount(); try await modernLoad.deactivate(); modernLoad.teardown()
        precondition(modernLoadTrace.factory == 1 && modernLoadTrace.checks == 0)
        print("完整旧上下文：load全参数/两种跨阶段拆分均先拒写后正确准备；跨阶段nonce/介质冲突拒绝，load RO优先；身份错误先于flush保RO；现代load原流程不变")
        let seedTrace = Trace(); let seed = try volume(image, seedTrace, legacy: false)
        let seedRoot = try seed.activate(taskOptions: ["rw,writeflow-media-id=\(media)"])
        try seed.mountVolume()
        _ = try await create(seed, seedRoot, "原始文件.txt")
        await seed.unmount(); try await seed.deactivate(); seed.teardown()
        // 直接用真实C引擎预置恶意磁盘同名属性；正式Swift入口永不读它来证明就绪。
        let diskTrace = Trace(); let raw = try backend(image, true, diskTrace)
        var e: Int32 = 0
        guard let h = nfsk_mount(raw.backend, false, &e) else { throw posixError(e) }
        let forged = Data("伪造就绪回执".utf8)
        for key in [ready + token, prepare + token, ready + other, "com.blteam.normal"] {
            let rc = key.withCString { k in forged.withUnsafeBytes { nfsk_setxattr(h, NFSK_ROOT_INO, k, $0.baseAddress, $0.count, Int32(NFSK_XATTR_SET)) } }
            precondition(rc == 0)
        }
        precondition(nfsk_umount(h) == 0); nfsk_backend_free(raw.backend); raw.cleanup()
        // C只读状态接口不发起任何设备读、写或同步；RO、正常RW与空句柄各有明确结果。
        precondition(nfsk_write_status(nil) == -EINVAL)
        for readOnly in [true, false] {
            let t = Trace(); let raw = try backend(image, !readOnly, t)
            guard let h = nfsk_mount(raw.backend, readOnly, &e) else { throw posixError(e) }
            let before = [koio_trace_reads(), koio_trace_pwrites(), koio_trace_syncs()]
            for _ in 0..<3 { precondition(nfsk_write_status(h) == (readOnly ? -EROFS : 0)) }
            precondition(before == [koio_trace_reads(), koio_trace_pwrites(), koio_trace_syncs()])
            precondition(nfsk_umount(h) == 0); nfsk_backend_free(raw.backend); raw.cleanup()
        }

        let t = Trace(); let v = try volume(image, t)
        let root = try v.activate(taskOptions: rw)
        let (file, _) = try await v.lookupItem(named: FSFileName(string: "原始文件.txt"), inDirectory: root)
        let before = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
        for operation in 0..<11 {
            await denied(EROFS) {
                switch operation {
                case 0: _ = try await create(v, root, "后台不可先写")
                case 1:
                    _ = try await v.createSymbolicLink(named: FSFileName(string: "拒绝符号链接"), inDirectory: root,
                        attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: "原始文件.txt"))
                case 2: _ = try await v.createLink(to: file, named: FSFileName(string: "拒绝硬链"), inDirectory: root)
                case 3: try await v.removeItem(file, named: FSFileName(string: "原始文件.txt"), fromDirectory: root)
                case 4:
                    _ = try await v.renameItem(file, inDirectory: root, named: FSFileName(string: "原始文件.txt"),
                        to: FSFileName(string: "拒绝改名"), inDirectory: root, overItem: nil)
                case 5: try await v.setXattr(named: FSFileName(string: "com.blteam.normal"), to: Data([1]), on: file, policy: .alwaysSet)
                case 6:
                    let attrs = FSItem.SetAttributesRequest(); attrs.modifyTime = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
                    _ = try await v.setAttributes(attrs, on: file)
                case 7: _ = try await v.write(contents: Data([1]), to: file, at: 0)
                case 8: _ = try await v.preallocateSpace(for: file, at: 0, length: 4096, flags: [])
                case 9: _ = try await v.setVolumeName(FSFileName(string: "拒绝卷名"))
                default: try await v.openItem(file, modes: [.write])
                }
            }
        }
        try v.mountVolume(taskOptions: rw)
        await denied(EROFS) { _ = try await create(v, root, "mount不得提前升级") }
        await denied(EAGAIN) { _ = try await v.xattr(named: FSFileName(string: ready + token), of: root) }
        await denied(EPERM) { _ = try await v.xattr(named: FSFileName(string: prepare + other), of: root) }
        await denied(EPERM) { _ = try await v.xattr(named: FSFileName(string: ready + other), of: root) }
        await denied(EPERM) { _ = try await v.xattr(named: FSFileName(string: prepare + token), of: file) }
        let fakeRoot = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: FSItem.Identifier.parentOfRoot.rawValue, name: FSFileName(string: "伪根"))
        await denied(EPERM) { _ = try await v.xattr(named: FSFileName(string: prepare + token), of: fakeRoot) }
        for prefix in [prepare, ready] {
            for policy in [FSVolume.SetXattrPolicy.alwaysSet, .delete] {
                await denied(EPERM) { try await v.setXattr(named: FSFileName(string: prefix + token), to: Data([1]), on: root, policy: policy) }
            }
        }
        let keys = try await v.xattrs(of: root)
        precondition(keys.contains { $0.string == "com.blteam.normal" })
        precondition(!keys.contains { ($0.string ?? "").hasPrefix(prepare) || ($0.string ?? "").hasPrefix(ready) })
        precondition(t.factory == 0 && t.checks == 0 && koio_trace_pwrites() == 0 && koio_trace_writable_mounts() == 0)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        try receipt(try await v.xattr(named: FSFileName(string: prepare + token), of: root))
        precondition(t.factory == 1 && t.checks == 1 && koio_trace_writable_mounts() == 1)
        await denied(EBUSY) { try v.mountVolume(taskOptions: ["ro"]) }
        await denied(EBUSY) { try await v.deactivate() }
        let writes = koio_trace_pwrites()
        let ioBeforeStatus = [koio_trace_reads(), writes, koio_trace_syncs()]
        try receipt(try await v.xattr(named: FSFileName(string: ready + token), of: root))
        try receipt(try await v.xattr(named: FSFileName(string: prepare + token), of: root))
        precondition(t.factory == 1 && t.checks == 1 && koio_trace_pwrites() == writes)
        precondition(ioBeforeStatus == [koio_trace_reads(), koio_trace_pwrites(), koio_trace_syncs()])
        let (directory, _) = try await v.createItem(named: FSFileName(string: "就绪握手"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let writtenFile = try await create(v, directory, "中文内容.txt")
        let content = Data("只有可信nonce准备后才允许写入".utf8)
        let count = try await v.write(contents: content, to: writtenFile, at: 0)
        precondition(count == content.count)
        try await v.synchronize(flags: .wait); await v.unmount()
        await denied(EROFS) { _ = try await v.xattr(named: FSFileName(string: ready + token), of: root) }
        try await v.deactivate(); v.teardown()
        precondition(t.cleanups == 2)
        print("握手正常：后台写/mount/status不升级；伪造nonce/根/磁盘属性/设置删除拒绝；prepare一次，ready幂等，中文真实引擎写入和正常卸载")

        for code in [EACCES, ENOTSUP, EIO] {
            let t = Trace(); t.failure = code
            let v = try volume(image, t); let root = try v.activate(taskOptions: rw)
            let before = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
            await denied(code) { _ = try await v.xattr(named: FSFileName(string: prepare + token), of: root) }
            t.failure = 0
            await denied(code) { _ = try await v.xattr(named: FSFileName(string: ready + token), of: root) }
            await denied(code) { _ = try await v.xattr(named: FSFileName(string: prepare + token), of: root) }
            _ = try await v.lookupItem(named: FSFileName(string: "原始文件.txt"), inDirectory: root)
            await denied(code) { _ = try await create(v, root, "能力失败不得写") }
            precondition(t.factory == 0 && t.checks == 1 && t.cleanups == 0)
            try await v.synchronize(flags: .wait); await v.unmount(); try await v.deactivate(); v.teardown()
            precondition(t.cleanups == 1 && koio_trace_pwrites() == 0)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        for value in [token.lowercased().replacingOccurrences(of: "1", with: "a"), "../" + token, "", token + "x", other + ",writeflow-ready-token=" + token] {
            let t = Trace(); let v = try volume(image, t)
            await denied(EINVAL) { _ = try v.activate(taskOptions: ["rw,writeflow-media-id=\(media),writeflow-ready-token=" + value]) }
            v.teardown(); precondition(t.factory == 0 && t.checks == 0 && t.cleanups == 1)
        }
        let mismatch = Trace(); let conflict = try volume(image, mismatch)
        _ = try conflict.activate(taskOptions: rw)
        await denied(EINVAL) { try conflict.mountVolume(taskOptions: ["rw,writeflow-media-id=10"]) }
        await denied(EINVAL) { try conflict.mountVolume(taskOptions: ["rw,writeflow-ready-token=" + other]) }
        conflict.teardown(); precondition(mismatch.factory == 0)
        let roTrace = Trace(); let ro = try volume(image, roTrace)
        let roRoot = try ro.activate(taskOptions: rw)
        try ro.mountVolume(taskOptions: ["ro"])
        await denied { _ = try await ro.xattr(named: FSFileName(string: prepare + token), of: roRoot) }
        await denied(EROFS) { _ = try await create(ro, roRoot, "后续RO优先") }
        await ro.unmount(); try await ro.deactivate(); ro.teardown()
        precondition(roTrace.factory == 0 && roTrace.checks == 0)
        for options in [["ro,writeflow-ready-token=" + token], ["writeflow-ready-token=" + token]] {
            let t = Trace(); let v = try volume(image, t)
            let root = try v.activate(taskOptions: options)
            await denied { _ = try await v.xattr(named: FSFileName(string: prepare + token), of: root) }
            await denied(EROFS) { _ = try await create(v, root, "无RW许可不准备") }
            v.teardown(); precondition(t.checks == 0 && t.factory == 0)
        }
        let noGate = Trace(); let noGateVolume = try volume(image, noGate, gate: false)
        let noGateRoot = try noGateVolume.activate(taskOptions: rw)
        await denied(ENOTSUP) { _ = try await noGateVolume.xattr(named: FSFileName(string: prepare + token), of: noGateRoot) }
        await denied(EAGAIN) { _ = try await noGateVolume.xattr(named: FSFileName(string: ready + token), of: noGateRoot) }
        noGateVolume.teardown(); precondition(noGate.checks == 0 && noGate.factory == 0)

        for legacy in [false, true] {
            let t = Trace(); let v = try volume(image, t, legacy: legacy)
            let options = legacy ? ["rw,writeflow-media-id=\(media)"] : rw
            let root = try v.activate(taskOptions: options)
            if !legacy { try v.mountVolume() }
            _ = try await create(v, root, legacy ? "无nonce仍延迟写" : "现代仍原写流程")
            await denied { _ = try await v.xattr(named: FSFileName(string: ready + token), of: root) }
            try await v.synchronize(flags: .wait); await v.unmount(); try await v.deactivate(); v.teardown()
            precondition(t.factory == 1 && t.checks == (legacy ? 1 : 0))
        }
        let dirtyTrace = Trace(); let dirty = try volume(image, dirtyTrace)
        let dirtyRoot = try dirty.activate(taskOptions: rw)
        try receipt(try await dirty.xattr(named: FSFileName(string: prepare + token), of: dirtyRoot))
        _ = try await create(dirty, dirtyRoot, "写回错误状态")
        koio_trace_fail_sync(1)
        await denied(EIO) { try await dirty.synchronize(flags: .wait) }
        koio_trace_fail_sync(0)
        let ioBeforeFailureQuery = [koio_trace_reads(), koio_trace_pwrites(), koio_trace_syncs()]
        for _ in 0..<3 {
            await denied(EIO) { _ = try await dirty.xattr(named: FSFileName(string: ready + token), of: dirtyRoot) }
            await denied(EIO) { _ = try await dirty.xattr(named: FSFileName(string: prepare + token), of: dirtyRoot) }
        }
        precondition(ioBeforeFailureQuery == [koio_trace_reads(), koio_trace_pwrites(), koio_trace_syncs()],
            "状态查询不得读写、sync或清除已锁存错误")
        await dirty.unmount(); try await dirty.deactivate(); dirty.teardown()
        precondition(dirtyTrace.status?.state == .notReady)
        print("状态只读：RO/正常RW/空句柄明确返回；真实引擎同步错误锁存后重复ready/prepare持续EIO、零I/O不清错")
        print("握手拒绝：三类同步失败保RO和零写；nonce格式/冲突/介质冲突/后续RO拒绝；无nonce与现代流程保持")
    }
}
