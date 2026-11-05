import Foundation
import FSKit

@main
struct LegacyActivation {
    final class Counter { var factory = 0; var cleanups = 0; var stale = false; var status: FSContainerStatus? }

    static func backend(_ image: String, writable: Bool, counter: Counter) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: { counter.cleanups += 1 }, writable: writable)
    }

    // 普通文件替代系统资源；复用生产选项转换和预检，ID匹配结果单独注入，不冒充真实IOMedia。
    static func volume(_ image: String, _ counter: Counter, load: [String] = [],
                       resourceWritable: Bool = true, returnedWritable: Bool = true,
                       legacy: Bool = true) throws -> ntfs3gVolume {
        let identity = { if counter.stale { throw posixError(ESTALE) } }
        let policy: ([String]) throws -> Bool = { options in
            try identity()
            return try !ntfs3gFileSystem.resolvedMountReadOnly(load + options, resourceWritable: resourceWritable)
        }
        return try ntfs3gVolume(backend: backend(image, writable: false, counter: counter),
            mountBackend: { options, currentReadOnly, source in
                let writable = try policy(options)
                guard writable == currentReadOnly else { return nil }
                return try ntfs3gFileSystem.backendForMount(readOnly: !writable, source: source,
                    validateIdentity: identity, makeBackend: { allowWrite in
                        counter.factory += 1
                        return try backend(image, writable: allowWrite && returnedWritable, counter: counter)
                    })
            }, onContainerStatusChange: { counter.status = $0 }, legacyOpenUnlink: true,
            legacyActivationPolicy: legacy ? policy : nil)
    }

    static func rejects(_ code: Int32, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("应拒绝操作：\(code)") }
        catch { precondition((error as NSError).code == Int(code), "错误码不符：\(error)") }
    }

    static func mkdir(_ volume: ntfs3gVolume, _ root: FSItem, _ name: String) async throws {
        _ = try await volume.createItem(named: FSFileName(string: name), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
    }

    static let rw = ["rw,nosuid,nodev,writeflow-media-id=9"]

    static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        let image = CommandLine.arguments[1]
        // 每种修改入口单独作为首次修改，避免mkdir先升级后掩盖遗漏的入口。
        for operation in ["创建目录", "符号链接", "硬链接", "移除", "重命名", "扩展属性", "元数据", "写入", "预分配", "卷名", "写打开", "先读打开后删除", "先读关闭后删除", "先读回收后删除"] {
            let seedCount = Counter()
            let seed = try volume(image, seedCount, legacy: false)
            let seedRoot = try seed.activate(taskOptions: rw)
            try seed.mountVolume()
            let sourceName = "入口文件-" + operation
            _ = try await seed.createItem(named: FSFileName(string: sourceName), type: .file,
                inDirectory: seedRoot, attributes: FSItem.SetAttributesRequest())
            await seed.unmount(); try await seed.deactivate(); seed.teardown()

            let count = Counter()
            let candidate = try volume(image, count)
            let before = try Data(contentsOf: URL(fileURLWithPath: image))
            let root = try candidate.activate(taskOptions: rw)
            let (file, _) = try await candidate.lookupItem(named: FSFileName(string: sourceName), inDirectory: root)
            precondition(count.factory == 0 && (try? Data(contentsOf: URL(fileURLWithPath: image))) == before,
                         "激活与只读lookup不得提前开启写入或改动镜像")
            switch operation {
            case "创建目录": try await mkdir(candidate, root, "入口目录")
            case "符号链接":
                _ = try await candidate.createSymbolicLink(named: FSFileName(string: "入口符号链接"), inDirectory: root,
                    attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: sourceName))
            case "硬链接": _ = try await candidate.createLink(to: file, named: FSFileName(string: "入口硬链接"), inDirectory: root)
            case "移除": try await candidate.removeItem(file, named: FSFileName(string: sourceName), fromDirectory: root)
            case "重命名":
                _ = try await candidate.renameItem(file, inDirectory: root, named: FSFileName(string: sourceName),
                    to: FSFileName(string: "入口重命名"), inDirectory: root, overItem: nil)
            case "扩展属性": try await candidate.setXattr(named: FSFileName(string: "com.blteam.legacy"), to: Data([1, 2]), on: file, policy: .alwaysSet)
            case "元数据":
                let request = FSItem.SetAttributesRequest(); request.modifyTime = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
                _ = try await candidate.setAttributes(request, on: file)
            case "先读关闭后删除", "先读回收后删除":
                try await candidate.openItem(file, modes: [.read])
                if operation == "先读关闭后删除" { try await candidate.closeItem(file, modes: []) }
                else { try await candidate.reclaimItem(file) }
                try await candidate.removeItem(file, named: FSFileName(string: sourceName), fromDirectory: root)
                await rejects(ENOENT) { _ = try await candidate.attributes(FSItem.GetAttributesRequest(), of: file) }
            case "先读打开后删除":
                try await candidate.openItem(file, modes: [.read])
                try await candidate.removeItem(file, named: FSFileName(string: sourceName), fromDirectory: root)
                _ = try await candidate.attributes(FSItem.GetAttributesRequest(), of: file)
                let bytes = Data("已打开文件仍存活".utf8)
                let n = try await candidate.write(contents: bytes, to: file, at: 0)
                precondition(n == bytes.count)
                try await candidate.closeItem(file, modes: [])
                await rejects(ENOENT) { _ = try await candidate.attributes(FSItem.GetAttributesRequest(), of: file) }
            case "写入":
                let bytes = Data("首次写入".utf8)
                let n = try await candidate.write(contents: bytes, to: file, at: 0)
                precondition(n == bytes.count)
            case "预分配": _ = try await candidate.preallocateSpace(for: file, at: 0, length: 4096, flags: [])
            case "卷名": _ = try await candidate.setVolumeName(FSFileName(string: "LegacyActivation"))
            default:
                try await candidate.openItem(file, modes: [.write])
                try await candidate.closeItem(file, modes: [])
            }
            precondition(count.factory == 1, "首次修改入口未执行一次完整权限转换：\(operation)")
            await rejects(EBUSY) { try candidate.mountVolume(taskOptions: ["ro,writeflow-media-id=10"]) }
            await rejects(EBUSY) { try await candidate.deactivate() }
            try await candidate.synchronize(flags: .wait)
            await candidate.unmount(); try await candidate.deactivate(); candidate.teardown()
            precondition(count.cleanups == 2, "修改后正常卸载必须精确清理：\(operation)")
        }
        print("首次修改入口通过：11种修改入口及读打开/关闭/回收跨升级均独立从RO升级且工厂只调用一次；异常迟到mount/deactivate拒绝，正常sync/unmount清理。")

        // 尚未修改的激活可以直接停用、卸载或被后续RO覆盖；所有路径保持原始字节。
        for lifecycle in ["停用", "先卸载", "后续RO", "加载RO", "默认RO", "26生命周期"] {
            let count = Counter()
            let candidate = try volume(image, count, load: lifecycle == "加载RO" ? ["--rdonly"] : [], legacy: lifecycle != "26生命周期")
            let before = try Data(contentsOf: URL(fileURLWithPath: image))
            let root = try candidate.activate(taskOptions: lifecycle == "默认RO" ? [] : rw)
            if lifecycle == "停用" {
                try await candidate.deactivate()
                await rejects(ENXIO) { try await mkdir(candidate, root, "不可创建") }
            } else {
                if lifecycle == "先卸载" { await candidate.unmount() }
                if lifecycle == "后续RO" { try candidate.mountVolume(taskOptions: ["ro"]) }
                await rejects(EROFS) { try await mkdir(candidate, root, "不可创建") }
                await candidate.unmount(); try await candidate.deactivate()
            }
            candidate.teardown()
            precondition(count.factory == 0 && count.cleanups == 1)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        print("无写入生命周期通过：停用/先卸载/后续RO/加载RO/默认RO/无兼容策略均不开RW且镜像不变。")

        for (options, writable, code) in [(rw, false, EROFS), (["rw"], true, ESTALE),
                                          (["rw,writeflow-media-id=9,writeflow-media-id=10"], true, EINVAL)] {
            let count = Counter(); let before = try Data(contentsOf: URL(fileURLWithPath: image))
            let candidate = try volume(image, count, resourceWritable: writable)
            await rejects(code) { _ = try candidate.activate(taskOptions: options) }
            candidate.teardown()
            precondition(count.factory == 0 && count.cleanups == 1 && count.status?.state == .notReady)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        let conflictCount = Counter(); let conflictBefore = try Data(contentsOf: URL(fileURLWithPath: image))
        let conflict = try volume(image, conflictCount)
        _ = try conflict.activate(taskOptions: rw)
        await rejects(EINVAL) { try conflict.mountVolume(taskOptions: ["rw,writeflow-media-id=10"]) }
        conflict.teardown()
        precondition(conflictCount.factory == 0 && conflictCount.cleanups == 1)
        precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == conflictBefore)

        for failure in ["脏卷", "休眠", "日志", "元数据", "身份变化", "不可写后端", "关闭失败"] {
            let count = Counter(); let before = try Data(contentsOf: URL(fileURLWithPath: image))
            let candidate = try volume(image, count, returnedWritable: failure != "不可写后端")
            let root = try candidate.activate(taskOptions: rw)
            let reasons = ["脏卷": Int32(NFSK_CHECK_DIRTY), "休眠": Int32(NFSK_CHECK_HIBERNATED),
                           "日志": Int32(NFSK_CHECK_JOURNAL), "元数据": Int32(NFSK_CHECK_METADATA)]
            nfsk_test_fail_preflight(reasons[failure] ?? 0)
            count.stale = failure == "身份变化"
            nfsk_test_fail_close(failure == "关闭失败" ? 1 : 0)
            let expected = failure == "身份变化" ? ESTALE : failure == "不可写后端" ? EROFS : EIO
            await rejects(expected) { try await mkdir(candidate, root, "门禁不得写入") }
            nfsk_test_fail_preflight(0); nfsk_test_fail_close(0)
            await rejects(ENXIO) { try await mkdir(candidate, root, "失败不得重试") }
            await candidate.unmount(); try await candidate.deactivate(); candidate.teardown()
            precondition(count.status?.state == .notReady)
            precondition(count.factory == (failure == "不可写后端" ? 1 : 0))
            precondition(count.cleanups == (failure == "不可写后端" ? 2 : 1), "失败应只清理一次：\(failure)")
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        for closeFailure in [false, true] {
            let count = Counter(); let candidate = try volume(image, count)
            let root = try candidate.activate(taskOptions: rw)
            try await mkdir(candidate, root, closeFailure ? "延迟关闭故障" : "延迟同步故障")
            nfsk_test_fail_sync(closeFailure ? 0 : 1); nfsk_test_fail_close(closeFailure ? 1 : 0)
            await candidate.unmount()
            nfsk_test_fail_sync(0); nfsk_test_fail_close(0)
            precondition(count.status?.state == .notReady)
            await rejects(ENXIO) { try await mkdir(candidate, root, "失败后不能写入") }
            try await candidate.deactivate(); candidate.teardown()
            precondition(count.factory == 1 && count.cleanups == 2)
        }
        let repeatedCount = Counter(); let repeated = try volume(image, repeatedCount)
        _ = try repeated.activate(taskOptions: rw)
        try await repeated.deactivate()
        let repeatedRoot = try repeated.activate(taskOptions: rw)
        try await mkdir(repeated, repeatedRoot, "未修改停用可再激活")
        await repeated.unmount(); try await repeated.deactivate(); repeated.teardown()
        precondition(repeatedCount.factory == 1 && repeatedCount.cleanups == 2)
        print("延迟升级卸载通过：同步与关闭故障保留notReady且清理一次；未修改停用后可重新激活。")
        print("写前失败通过：缺ID/冲突ID/资源RO/四类quickcheck/身份变化/不可写后端/关闭错误均拒绝，失败零数据修改且只清理一次。")
        print("此测试仅普通文件真实引擎和生产回调；没有系统VFS或真实IOMedia身份验收。")
    }
}
