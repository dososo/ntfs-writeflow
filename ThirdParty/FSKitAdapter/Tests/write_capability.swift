import Foundation
import FSKit

@main
struct WriteCapabilityChecks {
    final class Trace {
        var factory = 0
        var cleanups = 0
        var checks = 0
        var failure: Int32 = 0
        var status: FSContainerStatus?
    }

    static let rw = ["rw,writeflow-media-id=9"]
    static func backend(_ image: String, writable: Bool, trace: Trace) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: { trace.cleanups += 1 }, writable: writable)
    }

    static func volume(_ image: String, _ trace: Trace, legacy: Bool = true,
                       load: [String] = []) throws -> ntfs3gVolume {
        let policy: ([String]) throws -> Bool = { options in
            try !ntfs3gFileSystem.resolvedMountReadOnly(load + options, resourceWritable: true)
        }
        let version = OperatingSystemVersion(majorVersion: legacy ? 15 : 26, minorVersion: legacy ? 4 : 0, patchVersion: 0)
        return try ntfs3gFileSystem.volumeType(on: version).init(backend: backend(image, writable: false, trace: trace),
            mountBackend: { options, oldReadOnly, source in
                let readOnly = try !policy(options)
                guard readOnly != oldReadOnly else { return nil }
                return try ntfs3gFileSystem.backendForMount(readOnly: readOnly, source: source,
                    validateIdentity: {}, makeBackend: { writable in
                        trace.factory += 1
                        return try backend(image, writable: writable, trace: trace)
                    })
            }, onContainerStatusChange: { trace.status = $0 }, legacyOpenUnlink: true,
            legacyActivationPolicy: legacy ? policy : nil,
            validateWriteCapability: legacy ? { options in
                guard !ntfs3gFileSystem.defaultsToReadOnly(load + options) else { return }
                trace.checks += 1
                if trace.failure != 0 { throw posixError(trace.failure) }
            } : nil)
    }

    static func rejects(_ code: Int32, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("应拒绝操作：\(code)") }
        catch { precondition((error as NSError).code == Int(code), "错误码不符：\(error)") }
    }

    static func create(_ volume: ntfs3gVolume, _ root: FSItem, _ name: String) async throws -> FSItem {
        try await volume.createItem(named: FSFileName(string: name), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest()).0
    }

    static func main() async throws {
        let image = CommandLine.arguments[1]
        let seedTrace = Trace()
        let seed = try volume(image, seedTrace, legacy: false)
        let seedRoot = try seed.activate(taskOptions: rw)
        try seed.mountVolume()
        let file = try await create(seed, seedRoot, "只读保留.txt")
        let content = Data("能力失败后仍能读取原卷".utf8)
        let written = try await seed.write(contents: content, to: file, at: 0)
        precondition(written == content.count)
        try await seed.synchronize(flags: .wait)
        await seed.unmount(); try await seed.deactivate(); seed.teardown()

        for code in [EACCES, ENOTSUP, EIO] {
          for explicitMount in [false, true] {
            let trace = Trace(); trace.failure = code
            let candidate = try volume(image, trace)
            let root = try candidate.activate(taskOptions: rw)
            let before = try Data(contentsOf: URL(fileURLWithPath: image))
            koio_trace_reset()
            await rejects(code) {
                if explicitMount { try candidate.mountVolume(taskOptions: rw) }
                else { _ = try await create(candidate, root, "不得创建") }
            }
            precondition(trace.checks == 1 && trace.factory == 0 && trace.cleanups == 0,
                "能力失败必须保留原RO后端，不得创建或清理引擎")
            let (existing, _) = try await candidate.lookupItem(named: FSFileName(string: "只读保留.txt"), inDirectory: root)
            let attributes = try await candidate.attributes(FSItem.GetAttributesRequest(), of: existing)
            precondition(attributes.size == content.count, "失败后原RO句柄必须仍能读取元数据")
            // 即使外部能力恢复，本次已拒绝的实例也不自动恢复写入。
            trace.failure = 0
            for operation in 0..<11 {
                await rejects(code) {
                    switch operation {
                    case 0: _ = try await create(candidate, root, "继续拒绝")
                    case 1:
                        _ = try await candidate.createSymbolicLink(named: FSFileName(string: "拒绝链接"), inDirectory: root,
                            attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: "只读保留.txt"))
                    case 2: _ = try await candidate.createLink(to: existing, named: FSFileName(string: "拒绝硬链"), inDirectory: root)
                    case 3: try await candidate.removeItem(existing, named: FSFileName(string: "只读保留.txt"), fromDirectory: root)
                    case 4:
                        _ = try await candidate.renameItem(existing, inDirectory: root, named: FSFileName(string: "只读保留.txt"),
                            to: FSFileName(string: "拒绝改名"), inDirectory: root, overItem: nil)
                    case 5: try await candidate.setXattr(named: FSFileName(string: "com.blteam.capability"), to: Data([1]), on: existing, policy: .alwaysSet)
                    case 6:
                        let request = FSItem.SetAttributesRequest(); request.modifyTime = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
                        _ = try await candidate.setAttributes(request, on: existing)
                    case 7: _ = try await candidate.write(contents: Data([1]), to: existing, at: 0)
                    case 8: _ = try await candidate.preallocateSpace(for: existing, at: 0, length: 4096, flags: [])
                    case 9: _ = try await candidate.setVolumeName(FSFileName(string: "拒绝卷名"))
                    default: try await candidate.openItem(existing, modes: [.write])
                    }
                }
            }
            await rejects(code) { try candidate.mountVolume(taskOptions: rw) }
            await rejects(code) { try candidate.mountVolume(taskOptions: ["ro"]) }
            await withTaskGroup(of: Int.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        do { _ = try await create(candidate, root, "并发拒绝\(index)"); return 0 }
                        catch { return (error as NSError).code }
                    }
                }
                for await actual in group { precondition(actual == Int(code)) }
            }
            precondition(trace.checks == 1 && trace.factory == 0)
            precondition(koio_trace_writable_mounts() == 0 && koio_trace_pwrites() == 0)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
            // 没有可写引擎或脏数据，RO同步和普通卸载可完成；notReady仍保留原能力错误。
            try await candidate.synchronize(flags: .wait)
            await candidate.unmount(); try await candidate.deactivate()
            precondition(trace.status?.state == .notReady)
            await rejects(code) { _ = try candidate.activate(taskOptions: rw) }
            candidate.teardown(); candidate.teardown()
            precondition(trace.cleanups == 1 && koio_trace_pwrites() == 0)
            precondition((try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
            print("能力失败\(code)/显式mount=\(explicitMount)：原RO可读、11修改入口及并发拒绝、错误不变、同步及卸载停用完成、清理一次、零pwrite、镜像不变")
          }
        }

        for load in [[], ["ro"]] {
            let trace = Trace(); trace.failure = EIO
            let candidate = try volume(image, trace, load: load)
            let root = try candidate.activate(taskOptions: load.isEmpty ? [] : rw)
            let before = try Data(contentsOf: URL(fileURLWithPath: image)); koio_trace_reset()
            await rejects(EROFS) { _ = try await create(candidate, root, "默认仍只读") }
            await candidate.unmount(); try await candidate.deactivate(); candidate.teardown()
            precondition(trace.checks == 0 && trace.factory == 0 && trace.cleanups == 1)
            precondition(koio_trace_pwrites() == 0 && (try? Data(contentsOf: URL(fileURLWithPath: image))) == before)
        }
        let successTrace = Trace()
        let success = try volume(image, successTrace)
        let root = try success.activate(taskOptions: rw)
        koio_trace_reset()
        let (directory, _) = try await success.createItem(named: FSFileName(string: "同步许可"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let successFile = try await create(success, directory, "中文内容.txt")
        let bytes = Data("同步检查成功后才允许写入".utf8)
        let count = try await success.write(contents: bytes, to: successFile, at: 0)
        precondition(count == bytes.count && successTrace.checks == 1 && successTrace.factory == 1)
        precondition(koio_trace_writable_mounts() == 1 && koio_trace_pwrites() > 0)
        try await success.synchronize(flags: .wait)
        await success.unmount(); try await success.deactivate(); success.teardown()
        precondition(successTrace.cleanups == 2)

        let modernTrace = Trace(); modernTrace.failure = EIO
        let modern = try volume(image, modernTrace, legacy: false)
        let modernRoot = try modern.activate(taskOptions: rw)
        try modern.mountVolume()
        _ = try await create(modern, modernRoot, "现代流程不检查旧能力")
        try await modern.synchronize(flags: .wait)
        await modern.unmount(); try await modern.deactivate(); modern.teardown()
        precondition(modernTrace.checks == 0 && modernTrace.factory == 1 && modernTrace.cleanups == 2)
        print("默认RO/加载RO优先、能力成功中文写入及正常卸载、现代生命周期不执行旧门槛均通过")
        print("此处仅普通文件真实引擎，能力错误可控注入；不冒充系统metadataFlush或真实VFS通过")
    }
}
