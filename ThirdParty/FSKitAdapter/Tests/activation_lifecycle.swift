import Foundation
import FSKit

@main
struct ActivationLifecycle {
    final class CapturedResource {}
    final class Counter { var cleanups = 0; var factoryCalls = 0 }
    final class WeakResource { weak var value: CapturedResource? }

    static func backend(_ path: String, writable: Bool = false, counter: Counter) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(path, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil,
            cleanup: { counter.cleanups += 1 }, writable: writable)
    }

    static func expect(_ code: Int32, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("操作应被拒绝，错误码 \(code)") }
        catch { precondition((error as NSError).code == Int(code), "实际错误不符：\(error)") }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw posixError(EINVAL) }
        let image = CommandLine.arguments[1]
        let invalidImage = CommandLine.arguments[2]
        let before = try Data(contentsOf: URL(fileURLWithPath: image))

        // 预检必须在开启可写后端之前；失败保持原始介质且错误原因可见。
        for reason in [Int32(NFSK_CHECK_DIRTY), Int32(NFSK_CHECK_HIBERNATED),
                       Int32(NFSK_CHECK_JOURNAL), Int32(NFSK_CHECK_METADATA)] {
            let checkCounter = Counter()
            let ro = try backend(image, counter: checkCounter)
            nfsk_test_fail_preflight(reason)
            do {
                _ = try ntfs3gFileSystem.checkedWritableBackend(ro.backend, validateIdentity: {},
                    makeWritable: { checkCounter.factoryCalls += 1; return try backend(image, writable: true, counter: checkCounter) })
                preconditionFailure("预检失败不应创建可写后端")
            } catch {
                precondition((error as NSError).code == Int(EIO))
                precondition((error as NSError).userInfo["WriteFlowPreflightReason"] as? Int == Int(reason))
            }
            nfsk_test_fail_preflight(0)
            nfsk_backend_free(ro.backend); ro.cleanup()
            precondition(checkCounter.factoryCalls == 0 && checkCounter.cleanups == 1)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        let validCounter = Counter()
        let validRO = try backend(image, counter: validCounter)
        var revalidated = false
        let validRW = try ntfs3gFileSystem.checkedWritableBackend(validRO.backend,
            validateIdentity: { revalidated = true }, makeWritable: {
                precondition(revalidated); validCounter.factoryCalls += 1
                return try backend(image, writable: true, counter: validCounter)
            })
        nfsk_backend_free(validRW.backend); validRW.cleanup()
        nfsk_backend_free(validRO.backend); validRO.cleanup()
        precondition(validCounter.factoryCalls == 1 && validCounter.cleanups == 2)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)

        // 只读请求即使预检失败也不能反转成可写；工厂只接收false。
        let readOnlyCounter = Counter()
        let readOnlySource = try backend(image, counter: readOnlyCounter)
        nfsk_test_fail_preflight(Int32(NFSK_CHECK_DIRTY))
        let explicitRO = try ntfs3gFileSystem.backendForMount(readOnly: true, source: readOnlySource.backend,
            validateIdentity: {}, makeBackend: { writable in
                precondition(!writable); readOnlyCounter.factoryCalls += 1
                return try backend(image, writable: writable, counter: readOnlyCounter)
            })
        nfsk_test_fail_preflight(0)
        precondition(!explicitRO.writable && readOnlyCounter.factoryCalls == 1)
        nfsk_backend_free(explicitRO.backend); explicitRO.cleanup()
        nfsk_backend_free(readOnlySource.backend); readOnlySource.cleanup()

        let staleCounter = Counter()
        let staleRO = try backend(image, counter: staleCounter)
        expect(ESTALE) {
            _ = try ntfs3gFileSystem.checkedWritableBackend(staleRO.backend,
                validateIdentity: { throw posixError(ESTALE) },
                makeWritable: { staleCounter.factoryCalls += 1; return try backend(image, writable: true, counter: staleCounter) })
        }
        nfsk_backend_free(staleRO.backend); staleRO.cleanup()
        precondition(staleCounter.factoryCalls == 0)

        let gateCounter = Counter()
        var gateStatus: FSContainerStatus?
        let gated = try ntfs3gVolume(backend: backend(image, counter: gateCounter),
            mountBackend: { _, _, source in
                try ntfs3gFileSystem.checkedWritableBackend(source, validateIdentity: {}, makeWritable: {
                    gateCounter.factoryCalls += 1; return try backend(image, writable: true, counter: gateCounter)
                })
            }, onContainerStatusChange: { gateStatus = $0 })
        _ = try gated.activate(taskOptions: ["-o", "rw"])
        nfsk_test_fail_preflight(Int32(NFSK_CHECK_DIRTY))
        expect(EIO) { try gated.mountVolume() }
        nfsk_test_fail_preflight(0)
        precondition(gateStatus?.state == .notReady && gateCounter.factoryCalls == 0 && gateCounter.cleanups == 1)
        expect(ENXIO) { _ = try gated.activate(taskOptions: []) }
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        print("写前门禁通过：4类预检错误零可写工厂、成功后身份复核、身份变化拒绝、挂载预检失败清理且镜像不变。")

        let rejectedCounter = Counter()
        var captured: CapturedResource? = CapturedResource()
        let weakCaptured = WeakResource()
        weakCaptured.value = captured
        let rejected = try ntfs3gVolume(backend: backend(image, counter: rejectedCounter),
            mountBackend: { [resource = captured!] options, _, _ in
                withExtendedLifetime(resource) { }
                precondition(options == ["-o", "rw,writeflow-media-id=9"])
                rejectedCounter.factoryCalls += 1
                throw posixError(ESTALE)
            }, onContainerStatusChange: { _ in })
        captured = nil
        let rejectedRoot = try rejected.activate(taskOptions: ["-o", "rw,writeflow-media-id=9"])
        precondition(rejectedCounter.factoryCalls == 0, "激活过早进行身份校验或切换权限")
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [.fileID, .type]
        let attributes = try await rejected.attributes(request, of: rejectedRoot)
        precondition(attributes.type == .directory, "只读激活根项不可用")
        do {
            _ = try await rejected.createItem(named: FSFileName(string: "激活不能写入"), type: .file,
                inDirectory: rejectedRoot, attributes: FSItem.SetAttributesRequest())
            preconditionFailure("仅激活就允许写入")
        } catch { precondition((error as NSError).code == Int(EROFS)) }
        expect(ESTALE) { try rejected.mountVolume() }
        precondition(rejectedCounter.cleanups == 1 && weakCaptured.value == nil,
            "挂载拒绝后未释放后端或工厂闭包")
        try await rejected.deactivate()
        expect(ENXIO) { _ = try rejected.activate(taskOptions: []) }
        rejected.teardown()
        precondition(rejectedCounter.cleanups == 1, "重复清理")

        let originalCounter = Counter()
        let replacementCounter = Counter()
        let reopenFailure = try ntfs3gVolume(backend: backend(image, counter: originalCounter),
            mountBackend: { _, _, _ in try backend(invalidImage, writable: true, counter: replacementCounter) },
            onContainerStatusChange: { _ in })
        _ = try reopenFailure.activate(taskOptions: ["-o", "rw"])
        do { try reopenFailure.mountVolume(); preconditionFailure("无效后端不应挂载成功") }
        catch { }
        precondition(originalCounter.cleanups == 1 && replacementCounter.cleanups == 1,
            "重新打开失败后未释放原后端或替换后端")
        try await reopenFailure.deactivate()
        reopenFailure.teardown()
        precondition(originalCounter.cleanups == 1 && replacementCounter.cleanups == 1)

        let activeCounter = Counter()
        var active: ntfs3gVolume? = try ntfs3gVolume(backend: backend(image, counter: activeCounter),
            mountBackend: { _, _, _ in nil }, onContainerStatusChange: { _ in })
        _ = try active!.activate(taskOptions: [])
        expect(EBUSY) { _ = try active!.activate(taskOptions: []) }
        try active!.mountVolume()
        expect(EBUSY) { try active!.mountVolume() }
        precondition(activeCounter.cleanups == 0, "重复挂载破坏已有卷")
        try await active!.synchronize(flags: .wait)
        active = nil
        precondition(activeCounter.cleanups == 1, "析构未释放后端")
        let afterRejected = try Data(contentsOf: URL(fileURLWithPath: image))
        precondition(afterRejected == before,
            "错误身份及只读生命周期改变镜像内容")

        let rwCounter = Counter()
        let volume = try ntfs3gVolume(backend: backend(image, counter: rwCounter),
            mountBackend: { options, currentReadOnly, source in
                rwCounter.factoryCalls += 1
                let writable = !ntfs3gFileSystem.defaultsToReadOnly(options)
                if writable == !currentReadOnly { return nil }
                if writable {
                    return try ntfs3gFileSystem.checkedWritableBackend(source, validateIdentity: {},
                        makeWritable: { try backend(image, writable: true, counter: rwCounter) })
                }
                return try backend(image, writable: false, counter: rwCounter)
            }, onContainerStatusChange: { _ in })
        let root = try volume.activate(taskOptions: ["-o", "rw"])
        try volume.mountVolume()
        let (item, _) = try await volume.createItem(named: FSFileName(string: "生命周期往返.txt"), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let count = try await volume.write(contents: Data("生命周期".utf8), to: item, at: 0)
        precondition(count == Data("生命周期".utf8).count)
        await volume.unmount()
        do { _ = try await volume.write(contents: Data([1]), to: item, at: 0); preconditionFailure("卸载后允许写入") }
        catch { precondition((error as NSError).code == Int(EROFS)) }
        try await volume.deactivate()
        let beforeReadOnlyRemount = try Data(contentsOf: URL(fileURLWithPath: image))
        let readOnlyRoot = try volume.activate(taskOptions: ["-o", "rdonly"])
        precondition(root === readOnlyRoot, "重激活更换了系统缓存根项")
        try volume.mountVolume()
        let (reopened, _) = try await volume.lookupItem(named: FSFileName(string: "生命周期往返.txt"), inDirectory: root)
        do { _ = try await volume.write(contents: Data([2]), to: reopened, at: 0); preconditionFailure("只读重挂载允许写入") }
        catch { precondition((error as NSError).code == Int(EROFS)) }
        await volume.unmount()
        try await volume.deactivate()
        let afterReadOnlyRemount = try Data(contentsOf: URL(fileURLWithPath: image))
        precondition(beforeReadOnlyRemount == afterReadOnlyRemount, "只读重挂载改变镜像字节")
        _ = try volume.activate(taskOptions: ["-o", "rw"])
        try volume.mountVolume()
        let appended = try await volume.write(contents: Data([3]), to: reopened, at: off_t(count))
        precondition(appended == 1 && rwCounter.factoryCalls == 3)
        await volume.unmount()
        try await volume.deactivate()
        volume.teardown()
        precondition(rwCounter.cleanups == 3, "原后端或两次可写后端清理次数不符")
        let failedSyncCounter = Counter()
        var failedSyncStatus: FSContainerStatus?
        let failedSync = try ntfs3gVolume(backend: backend(image, counter: failedSyncCounter),
            mountBackend: { _, _, _ in nil }, onContainerStatusChange: { failedSyncStatus = $0 })
        _ = try failedSync.activate(taskOptions: [])
        try failedSync.mountVolume()
        nfsk_test_fail_sync(1)
        await failedSync.unmount()
        nfsk_test_fail_sync(0)
        precondition(failedSyncStatus?.state == .notReady && failedSyncCounter.cleanups == 1,
            "卸载同步失败被只读重开抹去")
        try await failedSync.deactivate()
        precondition(failedSyncStatus?.state == .notReady &&
            (failedSyncStatus?.status as NSError?)?.code == Int(EIO), "deactivate丢失原失败状态")
        expect(ENXIO) { _ = try failedSync.activate(taskOptions: []) }
        do { try await failedSync.synchronize(flags: .wait); preconditionFailure("失败卷后续sync谎报成功") }
        catch { precondition((error as NSError).code == Int(ENXIO)) }
        failedSync.teardown()
        precondition(failedSyncCounter.cleanups == 1, "失败卷重复清理")
        let failedCloseCounter = Counter()
        var failedCloseStatus: FSContainerStatus?
        let failedClose = try ntfs3gVolume(backend: backend(image, counter: failedCloseCounter),
            mountBackend: { _, _, _ in nil }, onContainerStatusChange: { failedCloseStatus = $0 })
        _ = try failedClose.activate(taskOptions: [])
        try failedClose.mountVolume()
        try await failedClose.synchronize(flags: .wait)
        nfsk_test_fail_close(1)
        await failedClose.unmount()
        nfsk_test_fail_close(0)
        precondition(failedCloseStatus?.state == .notReady && failedCloseCounter.cleanups == 1,
            "预同步成功后关闭失败仍重新打开卷")
        precondition((failedCloseStatus?.status as NSError?)?.code == Int(EIO), "关闭错误码丢失")
        expect(ENXIO) { _ = try failedClose.activate(taskOptions: []) }
        try await failedClose.deactivate()
        failedClose.teardown()
        precondition(failedCloseCounter.cleanups == 1, "关闭失败重复释放后端")
        print("生命周期通过：激活只读根项、mount身份拒绝且镜像不变、重开失败清理、重复激活和挂载保护、析构释放、读写→只读→读写重挂载、同一根项与既有文件有效。")
        print("卸载同步故障注入通过：保留notReady、拒绝后续激活和同步、不重复清理；关闭错误注入也保留notReady并阻止重开；均为适配层边界注入。")
        print("此测试未调用系统挂载；mount失败后的守护进程unload及直接detach需要系统验证。")
    }
}
