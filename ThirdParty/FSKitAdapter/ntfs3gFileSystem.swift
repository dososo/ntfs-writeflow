//
//  ntfs3gFileSystem.swift
//  FSUnaryFileSystem delegate: probes a resource (block device or image file),
//  loads it as an ntfs3gVolume (via libntfs-3g), and tears it down.
//

import Foundation
import FSKit
import IOKit

@available(macOS 15.4, *)
final class ntfs3gFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations,
                              FSManageableResourceMaintenanceOperations {

    private var volume: ntfs3gVolume?

    // 应用将所选 IOMedia 的不可复用登记标识随挂载请求传入。
    // 资源已由系统打开；核对后始终使用同一个资源，不再按设备名重新打开。
    static func expectedMediaID(_ options: [String]) throws -> UInt64? {
        var expected: UInt64?
        for option in options {
            let value = option.hasPrefix("-o") ? String(option.dropFirst(2)) : option
            for token in value.split(separator: ",", omittingEmptySubsequences: false) {
                let prefix = "writeflow-media-id="
                guard token.hasPrefix(prefix) else { continue }
                let digits = token.dropFirst(prefix.count)
                guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let id = UInt64(digits), id != 0,
                      expected == nil || expected == id else { throw posixError(EINVAL) }
                expected = id
            }
        }
        return expected
    }

    private static func validateIdentity(_ resource: FSResource, options: [String]) throws {
        guard let expected = try expectedMediaID(options) else { return }
        guard let block = resource as? FSBlockDeviceResource,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, block.bsdName) else {
            throw posixError(ESTALE)
        }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { throw posixError(ESTALE) }
        defer { IOObjectRelease(media) }
        var actual: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &actual) == KERN_SUCCESS,
              actual == expected, IORegistryEntryInPlane(media, kIOServicePlane) != 0 else {
            throw posixError(ESTALE)
        }
    }

    // 未明确请求 rw 时始终只读；不读取其他应用的共享偏好。
    static func defaultsToReadOnly(_ options: [String]) -> Bool {
        requestsReadOnly(options) || !requestsReadWrite(options)
    }

    /// `-r`, `--rdonly`, `--read-only`, bare `ro`/`rdonly`, or `-o <list>` containing them.
    private static func requestsReadOnly(_ taskOptions: [String]) -> Bool {
        matchOptions(taskOptions, tokens: ["ro", "rdonly"], flags: ["-r", "--rdonly", "--read-only", "rdonly", "ro"])
    }
    /// `-w`, bare `rw`, or `-o <list>` containing `rw`.
    private static func requestsReadWrite(_ taskOptions: [String]) -> Bool {
        matchOptions(taskOptions, tokens: ["rw"], flags: ["-w", "rw"])
    }

    private static func matchOptions(_ taskOptions: [String], tokens: Set<String>, flags: Set<String>) -> Bool {
        var i = 0
        while i < taskOptions.count {
            let opt = taskOptions[i]
            if flags.contains(opt) { return true }
            var oArg: String? = nil
            if opt == "-o", i + 1 < taskOptions.count { oArg = taskOptions[i + 1]; i += 1 }
            else if opt.hasPrefix("-o"), opt.count > 2 { oArg = String(opt.dropFirst(2)) }
            if let oArg {
                for tok in oArg.split(separator: ",") where tokens.contains(tok.trimmingCharacters(in: .whitespaces)) { return true }
            }
            i += 1
        }
        return false
    }

    // 调用时原只读引擎已关闭，resource仍是系统最初打开的同一资源。
    // 预检不修复或重放日志；成功后复核身份，最后才允许创建可写后端。
    static func checkedWritableBackend(_ readOnlyBackend: UnsafeMutableRawPointer,
                                       validateIdentity: () throws -> Void,
                                       makeWritable: () throws -> NTFSBackend) throws -> NTFSBackend {
        var reason: Int32 = 0
        let rc = nfsk_quick_check(readOnlyBackend, &reason)
        guard rc == 0 else {
            let detail: String
            switch reason {
            case Int32(NFSK_CHECK_DIRTY): detail = "NTFS 脏卷或磁盘检查尚未完成。"
            case Int32(NFSK_CHECK_HIBERNATED): detail = "Windows 休眠或快速启动状态阻止读写。"
            case Int32(NFSK_CHECK_JOURNAL): detail = "NTFS 日志未清理或不可读。"
            default: detail = "无法读取或验证 NTFS 核心元数据。"
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(-rc), userInfo: [
                NSLocalizedDescriptionKey: detail + " 未开启写入，未尝试修复。",
                "WriteFlowPreflightReason": Int(reason)
            ])
        }
        try validateIdentity()
        return try makeWritable()
    }

    static func backendForMount(readOnly: Bool, source: UnsafeMutableRawPointer,
                                validateIdentity: () throws -> Void,
                                makeBackend: (Bool) throws -> NTFSBackend) throws -> NTFSBackend {
        if readOnly {
            try validateIdentity()
            return try makeBackend(false)
        }
        return try checkedWritableBackend(source, validateIdentity: validateIdentity,
                                          makeWritable: { try makeBackend(true) })
    }

    // MARK: probe / load / unload

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        debugLog("probeResource resource=\(resourceTypeDescription(resource))")
        var e: Int32 = 0
        guard let made = Self.makeBackend(resource, allowWrite: false, out: &e) else {   // probe never writes
            debugLog("probeResource makeBackend failed errno=\(e)")
            replyHandler(.notRecognized, nil)
            return
        }
        var nameBuf = [CChar](repeating: 0, count: 1024)
        var serial: UInt64 = 0
        let recognized = nameBuf.withUnsafeMutableBufferPointer { nfsk_probe(made.backend, $0.baseAddress, $0.count, &serial) }
        let totalBytes = nfsk_block_total_bytes(made.backend)
        made.cleanup()
        nfsk_backend_free(made.backend)
        guard recognized == 1 else {
            debugLog("probeResource not recognized rc=\(recognized)")
            replyHandler(.notRecognized, nil)
            return
        }
        let label = String(cString: nameBuf)
        let uuid = NTFSVolumeSupport.volumeUUID(serial: serial, label: label, sizeBytes: totalBytes)
        let container = FSContainerIdentifier(uuid: uuid)
        debugLog("probeResource usable label=\(label) totalBytes=\(totalBytes) uuid=\(uuid.uuidString)")
        replyHandler(.usable(name: label, containerID: container), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        debugLog("loadResource start resource=\(resourceTypeDescription(resource)) options=\(options.taskOptions)")
        do { try Self.validateIdentity(resource, options: options.taskOptions) }
        catch { replyHandler(nil, error); return }
        let defaultReadOnly = Self.defaultsToReadOnly(options.taskOptions)
        var e: Int32 = 0
        // Block-device mount options arrive at activate, not load. Inspect metadata
        // read-only first, including when the user's default is read/write.
        guard let made = Self.makeBackend(resource, allowWrite: false, out: &e) else {
            let error = posixError(e)
            containerStatus = .notReady(status: error)
            debugLog("loadResource makeBackend failed errno=\(e)")
            replyHandler(nil, error)
            return
        }
        do {
            // ntfs3gVolume takes ownership of the backend; on failure its init frees
            // the backend and runs cleanup itself.
            let vol = try ntfs3gVolume(backend: made,
                                       mountBackend: { activationOptions, currentReadOnly, readOnlyBackend in
                                           let explicitOptions = options.taskOptions + activationOptions
                                           try Self.validateIdentity(resource, options: explicitOptions)
                                           let readOnly = Self.requestsReadOnly(explicitOptions) ? true
                                               : Self.requestsReadWrite(explicitOptions) ? false : defaultReadOnly
                                           guard readOnly != currentReadOnly else { return nil }
                                           return try Self.backendForMount(readOnly: readOnly, source: readOnlyBackend,
                                               validateIdentity: { try Self.validateIdentity(resource, options: explicitOptions) },
                                               makeBackend: { writable in
                                                   var error: Int32 = 0
                                                   guard let backend = Self.makeBackend(resource, allowWrite: writable, out: &error) else {
                                                       throw posixError(error)
                                                   }
                                                   return backend
                                               })
                                       },
                                       onContainerStatusChange: { [weak self] status in
                                           self?.containerStatus = status
                                       })
            self.volume = vol
            containerStatus = .ready
            debugLog("loadResource success name=\(vol.name.string ?? "") uuid=\(vol.volumeID.uuid.uuidString) initialReadOnly=true defaultReadOnly=\(defaultReadOnly)")
            replyHandler(vol, nil)
        } catch {
            containerStatus = .notReady(status: error as NSError)
            debugLog("loadResource failed error=\(error)")
            replyHandler(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        debugLog("unloadResource resource=\(resourceTypeDescription(resource)) options=\(options.taskOptions)")
        volume?.teardown()
        volume = nil
        containerStatus = .notReady(status: posixError(EAGAIN))
    }

    // MARK: backend construction

    /// Build an I/O backend for either a block device or an image file
    /// (`FSPathURLResource`, macOS 26+). `allowWrite` gates write access at the lowest
    /// level: probe/load pass false, activation passes the resolved write policy. The
    /// backend is opened writable only when the operation allows it AND the resource itself
    /// is writable — so a probe never holds a writable handle, and a read-only mount can't
    /// write to the underlying file/device even if the media is writable. Returns nil if the
    /// resource type is unsupported or the backend couldn't be opened (`err` set).
    private static func makeBackend(_ resource: FSResource, allowWrite: Bool, out err: inout Int32) -> NTFSBackend? {
        if let block = resource as? FSBlockDeviceResource {
            guard let b = nfsk_backend_from_block(Unmanaged.passUnretained(block).toOpaque(), allowWrite ? 1 : 0) else {
                err = errno == 0 ? ENOMEM : errno; return nil
            }
            return NTFSBackend(backend: b, retain: block, cleanup: {}, writable: allowWrite && block.isWritable)
        }
        if #available(macOS 26.0, *), let pathRes = resource as? FSPathURLResource {
            let url = pathRes.url
            let writable = allowWrite && pathRes.isWritable   // O_RDONLY unless writing is allowed
            let access = url.startAccessingSecurityScopedResource()
            var e: Int32 = 0
            let b = url.path.withCString { nfsk_backend_from_file($0, writable ? 1 : 0, &e) }
            guard let b else {
                if access { url.stopAccessingSecurityScopedResource() }
                err = (e != 0 ? e : EIO); return nil
            }
            return NTFSBackend(backend: b, retain: pathRes,
                           cleanup: { if access { url.stopAccessingSecurityScopedResource() } },
                           writable: writable)
        }
        err = EINVAL
        return nil
    }

    private func resourceTypeDescription(_ resource: FSResource) -> String {
        if let block = resource as? FSBlockDeviceResource {
            return "block(writable=\(block.isWritable))"
        }
        if #available(macOS 26.0, *), let path = resource as? FSPathURLResource {
            return "path(url=\(path.url.path), writable=\(path.isWritable))"
        }
        return String(describing: type(of: resource))
    }

    private func debugLog(_ message: String) {
        NSLog("[blntfs] \(message)")
    }

    // MARK: maintenance (required for block-device unary file systems)

    enum CheckMode {
        case quick, verify, repair

        init(options: [String]) throws {
            var flags = Set<Character>()
            for option in options {
                guard option.hasPrefix("-"), option.count > 1 else { throw posixError(EINVAL) }
                for flag in option.dropFirst() {
                    guard "nqy".contains(flag) else { throw posixError(EINVAL) }
                    flags.insert(flag)
                }
            }
            guard !(flags.contains("y") && (flags.contains("n") || flags.contains("q"))) else {
                throw posixError(EINVAL)
            }
            self = flags.contains("y") ? .repair : flags.contains("q") ? .quick : .verify
        }
    }

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let mode = try CheckMode(options: options.taskOptions)
        guard mode == .quick else {
            let message = mode == .repair
                ? "当前不支持修复 NTFS 卷，请使用 Windows 磁盘检查；未修改磁盘。"
                : "当前仅支持挂载前只读预检（-q），不提供完整文件系统校验；未修改磁盘。"
            task.logMessage(message)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let volume else { throw posixError(ENXIO) }
        let progress = Progress(totalUnitCount: 1)
        let work = DispatchGroup()
        work.enter()
        if #available(macOS 26.0, *) {
            task.cancellationHandler = {
                progress.cancel()
                work.wait()
                return nil
            }
        }
        debugLog("startCheck options=\(options.taskOptions)")
        DispatchQueue.global(qos: .utility).async {
            defer { work.leave() }
            var result: Error?
            do {
                guard !progress.isCancelled else { throw posixError(ECANCELED) }
                task.logMessage("正在只读检查 NTFS 挂载条件；这不是完整文件系统扫描。")
                try volume.quickCheck()
                guard !progress.isCancelled else { throw posixError(ECANCELED) }
                task.logMessage("NTFS 挂载预检通过；未执行修复或磁盘写入。")
            } catch {
                result = error
                task.logMessage(error.localizedDescription)
            }
            progress.completedUnitCount = 1
            task.didComplete(error: result)
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(ENOTSUP)
    }
}
