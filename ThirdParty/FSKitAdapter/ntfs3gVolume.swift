//
//  ntfs3gVolume.swift
//  An FSVolume backed by an NTFS filesystem through libntfs-3g.
//
//  libntfs-3g is not thread-safe, so every bridge call runs inside `withLock`
//  (a synchronous critical section — no `await` is held across the lock).
//

import FSKit
import Foundation

@inline(__always)
func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code == 0 ? EIO : code))
}

struct NTFSBackend {
    let backend: UnsafeMutableRawPointer
    let retain: AnyObject?
    let cleanup: () -> Void
    let writable: Bool
}

@available(macOS 15.4, *)
final class ntfs3gVolume: FSVolume, FSVolume.Operations, FSVolume.PathConfOperations,
                          FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations,
                          FSVolume.XattrOperations, FSVolume.RenameOperations,
                          FSVolume.PreallocateOperations {

    private var handle: OpaquePointer?
    private var backend: NTFSBackend?
    private var mountBackend: (([String], Bool, UnsafeMutableRawPointer) throws -> NTFSBackend?)?
    private let onContainerStatusChange: (FSContainerStatus) -> Void
    private var tornDown = false
    private var readOnly: Bool
    private var activated = false
    private var mounted = false
    private var activationOptions: [String] = []
    private let lock = NSLock()
    private var items: [UInt64: ntfs3gItem] = [:]
    private let rootItem: ntfs3gItem
    private let legacyOpenUnlink: Bool

    static var needsLegacyOpenUnlink: Bool {
        if #available(macOS 26.0, *) { return false }
        return true
    }

    /// `backend` comes from `nfsk_backend_from_block` / `nfsk_backend_from_file`.
    /// Ownership of `backend` transfers to this volume (freed in `teardown`).
    init(backend: NTFSBackend,
         mountBackend: @escaping ([String], Bool, UnsafeMutableRawPointer) throws -> NTFSBackend?,
         onContainerStatusChange: @escaping (FSContainerStatus) -> Void,
         legacyOpenUnlink: Bool = ntfs3gVolume.needsLegacyOpenUnlink) throws {
        var err: Int32 = 0
        guard let h = nfsk_mount(backend.backend, true, &err) else {
            backend.cleanup()
            nfsk_backend_free(backend.backend)
            throw posixError(err)
        }
        var st = nfsk_statfs_t()
        let statResult = nfsk_statfs(h, &st)
        guard statResult == 0 else {
            _ = nfsk_umount(h)
            nfsk_backend_free(backend.backend)
            backend.cleanup()
            throw posixError(-statResult)
        }
        let label = withUnsafeBytes(of: st.volume_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let volName = label.isEmpty ? "NTFS" : label
        let totalBytes = st.total_clusters &* UInt64(st.cluster_size)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO,
                              parentIno: FSItem.Identifier.parentOfRoot.rawValue,
                              name: FSFileName(string: volName))

        self.handle = h
        self.backend = backend
        self.readOnly = st.read_only != 0
        self.mountBackend = mountBackend
        self.onContainerStatusChange = onContainerStatusChange
        self.rootItem = root
        self.legacyOpenUnlink = legacyOpenUnlink

        let vid = FSVolume.Identifier(uuid: NTFSVolumeSupport.volumeUUID(serial: st.volume_serial, label: volName, sizeBytes: totalBytes))
        super.init(volumeID: vid, volumeName: FSFileName(string: volName))
        self.items[NFSK_ROOT_INO] = root
    }

    func teardown() {
        withLock { teardownLocked() }
    }

    // 调用方已持锁；激活失败和卸载共用同一所有权清理路径。
    private func teardownLocked() {
        if tornDown { return }
        tornDown = true
        activated = false
        mounted = false
        activationOptions = []
        if let h = handle { _ = nfsk_umount(h); handle = nil }
        if let b = backend { nfsk_backend_free(b.backend); b.cleanup(); backend = nil }
        mountBackend = nil
        items.removeAll()
    }

    deinit { teardown() }

    // MARK: lock helper (synchronous critical section)
    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func item(for ino: UInt64, parentIno: UInt64, name: FSFileName) -> ntfs3gItem {
        // FSKit identity is per-fileID (inode), so we cache one item per inode. The
        // parentIno/name held here are only a fallback hint: reported attributes take
        // their parent from the bridge (derived from the inode's FILE_NAME), so they
        // don't shift when the same inode is reached through another hard-link path.
        if let existing = items[ino] { return existing }
        let it = ntfs3gItem(ino: ino, parentIno: parentIno, name: name)
        items[ino] = it
        return it
    }

    fileprivate func makeAttributes(_ a: nfsk_attr_t, parentIno: UInt64, preferContext: Bool = false) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = FSItem.ItemType(rawValue: Int(a.type)) ?? .file
        attrs.mode = a.mode
        attrs.linkCount = a.nlink
        attrs.size = a.size
        attrs.allocSize = a.alloc_size
        attrs.fileID = FSItem.Identifier(rawValue: a.ino) ?? .invalid
        // Parent reporting: directory enumeration knows the directory being listed and
        // passes preferContext=true to report it, so a hard link's parentID stays
        // consistent with the directory it appears in. Context-free attributes(of:)
        // instead prefer the stable parent the bridge derives from the inode's
        // FILE_NAME (not mutated by lookups, so a held handle's parentID can't be
        // corrupted by another hard-link path), falling back to the supplied hint.
        let parent = preferContext ? parentIno : (a.parent_ino != 0 ? a.parent_ino : parentIno)
        attrs.parentID = FSItem.Identifier(rawValue: parent) ?? .invalid
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = a.flags
        attrs.modifyTime = timespec(tv_sec: Int(a.mtime_sec), tv_nsec: Int(a.mtime_nsec))
        attrs.accessTime = timespec(tv_sec: Int(a.atime_sec), tv_nsec: Int(a.atime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(a.ctime_sec), tv_nsec: Int(a.ctime_nsec))
        attrs.birthTime  = timespec(tv_sec: Int(a.btime_sec), tv_nsec: Int(a.btime_nsec))
        return attrs
    }

    fileprivate func attributes(ino: UInt64, parentIno: UInt64) -> FSItem.Attributes? {
        withLock {
            guard let h = handle else { return nil }
            var a = nfsk_attr_t()
            if nfsk_getattr(h, ino, &a) != 0 { return nil }
            return makeAttributes(a, parentIno: parentIno)
        }
    }

    // MARK: properties
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = true           // via ntfs_link (writable mounts)
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = true
        caps.supports64BitObjectIDs = true
        caps.supports2TBFiles = true
        caps.supportsSparseFiles = true
        // NTFS 的未初始化区间和稀疏洞都由引擎返回零；系统仍可能下发实体补零回调。
        caps.supportsZeroRuns = true
        caps.supportsHiddenFiles = true
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        // 与扩展 FSShortName 一致，用于识别确由本后端挂载的卷。
        let stats = FSStatFSResult(fileSystemTypeName: "blntfs")
        return withLock {
            guard let h = handle else { return stats }
            var st = nfsk_statfs_t()
            guard nfsk_statfs(h, &st) == 0 else { return stats }
            let bs = Int(st.cluster_size == 0 ? 4096 : st.cluster_size)
            stats.blockSize = bs
            stats.ioSize = bs
            stats.totalBlocks = st.total_clusters
            stats.availableBlocks = st.free_clusters
            stats.freeBlocks = st.free_clusters
            stats.usedBlocks = st.total_clusters > st.free_clusters ? st.total_clusters - st.free_clusters : 0
            stats.totalFiles = st.total_files
            stats.freeFiles = st.free_files
            return stats
        }
    }

    // FSKit retains unlinked/overwritten open files until their last reference closes.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool = true

    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { withLock { readOnly ? [.readOnly] : [] } }
        set { }
    }

    // MARK: lifecycle
    func quickCheck() throws {
        try withLock {
            guard !tornDown, let backend, handle != nil else { throw posixError(ENXIO) }
            guard !activated, readOnly else { throw posixError(EBUSY) }
            var reason: Int32 = 0
            let rc = nfsk_quick_check(backend.backend, &reason)
            guard rc == 0 else {
                let detail: String
                switch reason {
                case Int32(NFSK_CHECK_DIRTY): detail = "NTFS 卷被标记为脏卷，或 Windows 磁盘检查尚未完成。"
                case Int32(NFSK_CHECK_HIBERNATED): detail = "Windows 休眠或快速启动状态阻止读写挂载，请先完全关闭 Windows。"
                case Int32(NFSK_CHECK_JOURNAL): detail = "NTFS 日志未清理、不可读或仍包含 Windows 缓存元数据。"
                default: detail = "无法读取或验证 NTFS 核心元数据。"
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(-rc), userInfo: [
                    NSLocalizedDescriptionKey: detail + " 未尝试修复。"
                ])
            }
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        try activate(taskOptions: options.taskOptions)
    }

    // 激活只提供真实可用的只读根项；挂载阶段才处理身份与写入权限。
    func activate(taskOptions: [String]) throws -> FSItem {
        try withLock {
            guard !tornDown, handle != nil else { throw posixError(ENXIO) }
            guard !activated, !mounted, readOnly else { throw posixError(EBUSY) }
            activationOptions = taskOptions
            activated = true
        }
        onContainerStatusChange(.active)
        return rootItem
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        let closed = try withLock {
            guard !mounted else { throw posixError(EBUSY) }
            activated = false
            activationOptions = []
            return tornDown
        }
        // 已清理的失败卷保留原 notReady 错误，不改写为通用错误或 ready。
        if !closed { onContainerStatusChange(.ready) }
    }

    func mount(options: FSTaskOptions) async throws {
        try mountVolume()
    }

    // 与系统入口共用，离线测试无需伪造系统保留的 FSTaskOptions。
    func mountVolume() throws {
        try withLock {
            guard !tornDown, handle != nil, activated else { throw posixError(ENXIO) }
            guard !mounted else { throw posixError(EBUSY) }
            do {
                // 先关闭只读引擎；预检与重开在同一资源上串行，不保留并行引擎。
                guard let previous = backend else { throw posixError(ENXIO) }
                if let h = handle {
                    let rc = nfsk_umount(h)
                    handle = nil
                    if rc != 0 { throw posixError(-rc) }
                }
                let replacement = try mountBackend?(activationOptions, readOnly, previous.backend)
                let engineReadOnly = replacement.map { !$0.writable } ?? readOnly
                if let replacement {
                    nfsk_backend_free(previous.backend); previous.cleanup()
                    backend = replacement
                }
                guard let selected = backend else { throw posixError(ENXIO) }
                var err: Int32 = 0
                guard let h = nfsk_mount(selected.backend, engineReadOnly, &err) else {
                    throw posixError(err)
                }
                handle = h
                var st = nfsk_statfs_t()
                let rc = nfsk_statfs(h, &st)
                guard rc == 0 else { throw posixError(-rc) }
                readOnly = st.read_only != 0
                if #unavailable(macOS 26.4), readOnly && backend?.writable == true {
                    throw posixError(EROFS)
                }
                mounted = true
            } catch {
                teardownLocked()
                onContainerStatusChange(.notReady(status: error))
                throw error
            }
        }
    }

    func unmount() async {
        var failure: Error?
        withLock {
            guard mounted, let h = handle, let backend else { return }
            let rc = nfsk_sync(h)
            if rc != 0 {
                failure = posixError(-rc)
                teardownLocked()
                return
            }
            // unmount 允许清理 I/O；deactivate 不应再访问介质。
            // 同一后端重开只读引擎，根项只含 MFT 编号，不持有失效的 C 句柄。
            let closeResult = nfsk_umount(h)
            handle = nil
            if closeResult != 0 {
                failure = posixError(-closeResult)
                teardownLocked()
                return
            }
            mounted = false
            readOnly = true
            var err: Int32 = 0
            if let reopened = nfsk_mount(backend.backend, true, &err) {
                handle = reopened
            } else {
                failure = posixError(err)
                teardownLocked()
            }
        }
        if let failure {
            NSLog("[blntfs] 卸载清理失败：\(failure)")
            onContainerStatusChange(.notReady(status: failure))
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        try withLock {
            guard let h = handle else { throw posixError(ENXIO) }
            let rc = nfsk_sync(h)
            if rc != 0 { throw posixError(-rc) }
        }
    }

    // MARK: attributes
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var a = nfsk_attr_t()
            let rc = nfsk_getattr(h, it.ino, &a)
            if rc != 0 { throw posixError(-rc) }
            return makeAttributes(a, parentIno: it.parentIno)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            return try applyAttributes(newAttributes, ino: it.ino, parent: it.parentIno, handle: h)
        }
    }

    private func metadataRequest(_ request: FSItem.SetAttributesRequest) throws -> nfsk_metadata_t {
        guard !request.isValid(.backupTime) else { throw posixError(ENOTSUP) }
        if request.isValid(.size), request.size > UInt64(Int64.max) { throw posixError(EFBIG) }
        var metadata = nfsk_metadata_t()
        if request.isValid(.modifyTime) {
            metadata.valid |= UInt32(NFSK_SET_MTIME)
            metadata.mtime_sec = Int64(request.modifyTime.tv_sec)
            metadata.mtime_nsec = Int64(request.modifyTime.tv_nsec)
        }
        if request.isValid(.accessTime) {
            metadata.valid |= UInt32(NFSK_SET_ATIME)
            metadata.atime_sec = Int64(request.accessTime.tv_sec)
            metadata.atime_nsec = Int64(request.accessTime.tv_nsec)
        }
        if request.isValid(.birthTime) {
            metadata.valid |= UInt32(NFSK_SET_BTIME)
            metadata.btime_sec = Int64(request.birthTime.tv_sec)
            metadata.btime_nsec = Int64(request.birthTime.tv_nsec)
        }
        if request.isValid(.flags) {
            metadata.valid |= UInt32(NFSK_SET_FLAGS)
            metadata.flags = request.flags
        }
        let rc = nfsk_validate_metadata(&metadata)
        if rc != 0 { throw posixError(-rc) }
        return metadata
    }

    // Called with the volume lock held, including while initializing a new item.
    private func applyAttributes(_ request: FSItem.SetAttributesRequest, ino: UInt64,
                                 parent: UInt64, handle: OpaquePointer) throws -> FSItem.Attributes {
        guard !readOnly else { throw posixError(EROFS) }
        var metadata = try metadataRequest(request)
        var attributes = nfsk_attr_t()
        let initial = nfsk_getattr(handle, ino, &attributes)
        if initial != 0 { throw posixError(-initial) }
        request.consumedAttributes = []
        // Preserve the existing ignored-ownership policy: mode/uid/gid remain
        // unconsumed. Rejecting them here also rejects otherwise valid copy metadata.
        if request.isValid(.size) {
            if attributes.type == UInt32(NFSK_TYPE_FILE) {
                let rc = nfsk_truncate(handle, ino, request.size)
                if rc != 0 { throw posixError(-rc) }
            } else if request.size != attributes.size { throw posixError(EINVAL) }
            request.consumedAttributes.insert(.size)
        }
        if metadata.valid != 0 {
            let rc = nfsk_set_metadata(handle, ino, &metadata)
            if rc != 0 { throw posixError(-rc) }
            for attribute: FSItem.Attribute in [.modifyTime, .accessTime, .birthTime, .flags] where request.isValid(attribute) {
                request.consumedAttributes.insert(attribute)
            }
        }
        let rc = nfsk_getattr(handle, ino, &attributes)
        if rc != 0 { throw posixError(-rc) }
        return makeAttributes(attributes, parentIno: parent)
    }

    // MARK: lookup / reclaim
    private func resolvedName(_ name: String, in directory: UInt64, handle: OpaquePointer) throws -> (UInt64, FSFileName) {
        var error: Int32 = 0
        var canonical = [CChar](repeating: 0, count: 1024)
        let ino = name.withCString { requested in
            canonical.withUnsafeMutableBufferPointer { buffer in
                nfsk_lookup_name(handle, directory, requested, buffer.baseAddress, buffer.count, &error)
            }
        }
        guard ino != 0 else { throw posixError(error == 0 ? ENOENT : error) }
        return (ino, FSFileName(string: String(cString: canonical)))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            let (ino, fsName) = try resolvedName(nameStr, in: dir.ino, handle: h)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        try withLock {
            guard let it = item as? ntfs3gItem else { return }
            guard it.ino != NFSK_ROOT_INO else { return }
            if legacyOpenUnlink, items[it.ino] === it, let handle {
                let rc = nfsk_close_item(handle, it.ino)
                if rc != 0 { throw posixError(-rc) }
            }
            let removeCachedItem = {
                if self.items[it.ino] === it { self.items.removeValue(forKey: it.ino) }
            }
            // 当前基线 SDK 不提供 macOS 27 的 tryReclaim。
            removeCachedItem()
        }
    }

    private func evictDeletedItem(_ item: FSItem, handle: OpaquePointer) {
        guard let it = item as? ntfs3gItem, items[it.ino] === it else { return }
        var attributes = nfsk_attr_t()
        // NTFS may immediately reuse the record. A later create must get a new
        // FSItem, even if FSKit has not delivered the deleted object's reclaim yet.
        if nfsk_getattr(handle, it.ino, &attributes) == -ENOENT {
            items.removeValue(forKey: it.ino)
        }
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = buf.withUnsafeMutableBufferPointer { nfsk_readlink(h, it.ino, $0.baseAddress, $0.count) }
            if rc != 0 { throw posixError(-rc) }
            return FSFileName(string: String(cString: buf))
        }
    }

    // MARK: create / remove / rename
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            guard type == .file || type == .directory else { throw posixError(ENOTSUP) }
            _ = try metadataRequest(newAttributes)
            let kind = UInt32(type == .directory ? NFSK_TYPE_DIR : NFSK_TYPE_FILE)
            var err: Int32 = 0
            let ino = nameStr.withCString { nfsk_create(h, dir.ino, $0, kind, &err) }
            if ino == 0 { throw posixError(err) }
            do { _ = try applyAttributes(newAttributes, ino: ino, parent: dir.ino, handle: h) }
            catch {
                let cleanup = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
                if cleanup != 0 { NSLog("[blntfs] failed to remove incompletely initialized item: errno \(-cleanup)") }
                throw error
            }
            let fsName = FSFileName(string: nameStr)
            items.removeValue(forKey: ino)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle,
                  let nameStr = name.string, let target = contents.string,
                  !nameStr.utf8.contains(0), !target.utf8.contains(0) else { throw posixError(EINVAL) }
            _ = try metadataRequest(newAttributes)
            var error: Int32 = 0
            let ino = nameStr.withCString { name in
                target.withCString { nfsk_symlink(h, dir.ino, name, $0, &error) }
            }
            guard ino != 0 else { throw posixError(error) }
            do { _ = try applyAttributes(newAttributes, ino: ino, parent: dir.ino, handle: h) }
            catch {
                let cleanup = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
                if cleanup != 0 { NSLog("[blntfs] failed to remove incompletely initialized symlink: errno \(-cleanup)") }
                throw error
            }
            let actual = FSFileName(string: nameStr)
            items.removeValue(forKey: ino)
            return (item(for: ino, parentIno: dir.ino, name: actual), actual)
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        try withLock {
            guard let target = item as? ntfs3gItem, let dir = directory as? ntfs3gItem,
                  let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let rc = nameStr.withCString { nfsk_link(h, target.ino, dir.ino, $0, &err) }
            if rc != 0 { throw posixError(err) }
            return FSFileName(string: nameStr)
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            let rc = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
            if rc != 0 { throw posixError(-rc) }
            evictDeletedItem(item, handle: h)
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        try withLock {
            guard let sdir = sourceDirectory as? ntfs3gItem, let ddir = destinationDirectory as? ntfs3gItem,
                  let h = handle, let src = sourceName.string, let dst = destinationName.string else { throw posixError(EINVAL) }
            let rc = src.withCString { sp in dst.withCString { dp in nfsk_rename(h, sdir.ino, sp, ddir.ino, dp) } }
            if rc != 0 { throw posixError(-rc) }
            if let overItem { evictDeletedItem(overItem, handle: h) }
            let (_, actualName) = try resolvedName(dst, in: ddir.ino, handle: h)
            if let it = item as? ntfs3gItem {
                it.parentIno = ddir.ino
                it.name = actualName
            }
            return actualName
        }
    }

    // MARK: enumeration
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let wantDots = (attributes == nil)
            let c = cookie.rawValue
            let ctx = EnumContext(volume: self, packer: packer, parentIno: dir.ino, wantAttributes: attributes != nil)

            if wantDots {
                if c < 1 {
                    if !ctx.packRaw(name: ".", ino: dir.ino, type: UInt32(NFSK_TYPE_DIR), nextCookie: 1) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
                if c < 2 {
                    if !ctx.packRaw(name: "..", ino: dir.ino, type: UInt32(NFSK_TYPE_DIR), nextCookie: 2) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
            }
            guard c <= UInt64(Int64.max) else { throw posixError(EINVAL) }
            let realSkip: Int64 = c <= 2 ? 0 : Int64(c - 2)
            let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()
            let rc = nfsk_readdir(h, dir.ino, realSkip, ctxPtr, enumTrampoline)
            if rc != 0 && !ctx.stopped { throw posixError(-rc) }
            return FSDirectoryVerifier(rawValue: 1)
        }
    }

    // MARK: PathConf
    var maximumLinkCount: Int { 1023 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    // FSKit's automatic conversion adds one; UInt64.max overflows and makes
    // Finder see a 2 GiB limit. Match the bridge's signed 64-bit file offsets.
    var maximumFileSizeInBits: Int { 64 }
    var maximumXattrSize: Int { Int(NFSK_MAX_XATTR_SIZE) }

    // MARK: Extended attributes
    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = name.string, !key.utf8.contains(0) else { throw posixError(EINVAL) }
            return try key.withCString { key in
                let size = nfsk_getxattr(h, it.ino, key, nil, 0)
                if size < 0 { throw posixError(Int32(-size)) }
                var data = Data(count: Int(size))
                let read = data.withUnsafeMutableBytes { nfsk_getxattr(h, it.ino, key, $0.baseAddress, $0.count) }
                if read < 0 { throw posixError(Int32(-read)) }
                guard read == size else { throw posixError(EIO) }
                return data
            }
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = name.string, !key.utf8.contains(0) else { throw posixError(EINVAL) }
            let bridgePolicy: Int32
            switch policy {
            case .alwaysSet: bridgePolicy = Int32(NFSK_XATTR_SET)
            case .mustCreate: bridgePolicy = Int32(NFSK_XATTR_CREATE)
            case .mustReplace: bridgePolicy = Int32(NFSK_XATTR_REPLACE)
            case .delete: bridgePolicy = Int32(NFSK_XATTR_DELETE)
            @unknown default: throw posixError(EINVAL)
            }
            let rc: Int32 = try key.withCString { key in
                if policy == .delete { return nfsk_setxattr(h, it.ino, key, nil, 0, bridgePolicy) }
                guard let value else { throw posixError(EINVAL) }
                return value.withUnsafeBytes { nfsk_setxattr(h, it.ino, key, $0.baseAddress, $0.count, bridgePolicy) }
            }
            if rc < 0 { throw posixError(-rc) }
        }
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let size = nfsk_listxattr(h, it.ino, nil, 0)
            if size < 0 { throw posixError(Int32(-size)) }
            if size == 0 { return [] }
            var bytes = [CChar](repeating: 0, count: Int(size))
            let read = bytes.withUnsafeMutableBufferPointer { nfsk_listxattr(h, it.ino, $0.baseAddress, $0.count) }
            if read < 0 { throw posixError(Int32(-read)) }
            guard read == size else { throw posixError(EIO) }
            return try bytes.split(separator: 0).map { name in
                guard let string = String(bytes: name.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw posixError(EIO)
                }
                return FSFileName(string: string)
            }
        }
    }

    // MARK: ReadWrite
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            guard offset >= 0, length >= 0 else { throw posixError(EINVAL) }
            let cap = min(length, buffer.length)
            guard Int64(cap) <= Int64.max - Int64(offset) else { throw posixError(EOVERFLOW) }
            var err: Int32 = 0
            let n = buffer.withUnsafeMutableBytes { raw in
                nfsk_read(h, it.ino, Int64(offset), raw.baseAddress, Int64(cap), &err)
            }
            if n < 0 { throw posixError(err) }
            return Int(n)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            guard !readOnly else { throw posixError(EROFS) }
            guard offset >= 0, contents.count <= Int64.max - offset else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let n = contents.withUnsafeBytes { raw in
                nfsk_write(h, it.ino, Int64(offset), raw.baseAddress, Int64(raw.count), &err)
            }
            if n < 0 { throw posixError(err) }
            return Int(n)
        }
    }

    // MARK: Volume name / preallocation
    func setVolumeName(_ name: FSFileName) async throws -> FSFileName {
        try withLock {
            guard let h = handle, let label = name.string, !label.utf8.contains(0) else { throw posixError(EINVAL) }
            let rc = label.withCString { nfsk_rename_volume(h, $0) }
            if rc != 0 { throw posixError(-rc) }
            self.name = name
            rootItem.name = name
            return name
        }
    }

    func preallocateSpace(for item: FSItem, at offset: off_t, length: Int,
                          flags: FSVolume.PreallocateFlags) async throws -> Int {
        try withLock {
            guard let h = handle, let item = item as? ntfs3gItem else { throw posixError(EINVAL) }
            guard !readOnly else { throw posixError(EROFS) }
            let supported: FSVolume.PreallocateFlags = [.all, .persist, .fromEOF]
            guard flags.subtracting(supported).isEmpty else { throw posixError(ENOTSUP) }
            let rc = nfsk_preallocate(h, item.ino, Int64(offset), Int64(length), flags.contains(.fromEOF))
            if rc < 0 { throw posixError(Int32(-rc)) }
            return Int(rc)
        }
    }

    // MARK: OpenClose
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        try withLock {
            guard let h = handle, let it = item as? ntfs3gItem else { throw posixError(EINVAL) }
            if readOnly && modes.contains(.write) { throw posixError(EROFS) }
            guard legacyOpenUnlink else { return }
            let rc = nfsk_open_item(h, it.ino)
            if rc != 0 { throw posixError(-rc) }
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard legacyOpenUnlink, modes.isEmpty else { return }
        try withLock {
            guard let h = handle, let it = item as? ntfs3gItem else { throw posixError(EINVAL) }
            guard items[it.ino] === it else { return }
            let rc = nfsk_close_item(h, it.ino)
            if rc != 0 { throw posixError(-rc) }
            evictDeletedItem(item, handle: h)
        }
    }
}

// 当前 SDK 不支持 SeekRegionHandler；不声明该能力。

// MARK: - Directory enumeration trampoline

@available(macOS 15.4, *)
final class EnumContext {
    unowned let volume: ntfs3gVolume
    let packer: FSDirectoryEntryPacker
    let parentIno: UInt64
    let wantAttributes: Bool
    var stopped = false

    init(volume: ntfs3gVolume, packer: FSDirectoryEntryPacker, parentIno: UInt64, wantAttributes: Bool) {
        self.volume = volume
        self.packer = packer
        self.parentIno = parentIno
        self.wantAttributes = wantAttributes
    }

    func packRaw(name: String, ino: UInt64, type: UInt32, nextCookie: UInt64) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .directory
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: nextCookie), attributes: nil)
        if !ok { stopped = true }
        return ok
    }

    func pack(name: String, ino: UInt64, type: UInt32, bridgeCookie: Int64) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .file
        var attrs: FSItem.Attributes? = nil
        if wantAttributes {
            attrs = volume.enumAttributesRaw(ino: ino, parentIno: parentIno)
        }
        let next = UInt64(bridgeCookie) + 2
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: next), attributes: attrs)
        if !ok { stopped = true }
        return ok
    }
}

@available(macOS 15.4, *)
extension ntfs3gVolume {
    // Called from the readdir trampoline while the lock is already held, so it
    // must NOT re-take the lock; access the bridge directly.
    fileprivate func enumAttributesRaw(ino: UInt64, parentIno: UInt64) -> FSItem.Attributes? {
        guard let h = handle else { return nil }
        var a = nfsk_attr_t()
        if nfsk_getattr(h, ino, &a) != 0 { return nil }
        return makeAttributes(a, parentIno: parentIno, preferContext: true)
    }
}

@available(macOS 15.4, *)
let enumTrampoline: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt64, UInt32, Int64) -> Int32 = {
        ctxPtr, namePtr, ino, type, cookie in
        guard let ctxPtr = ctxPtr, let namePtr = namePtr else { return 1 }
        let ctx = Unmanaged<EnumContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let cont = ctx.pack(name: String(cString: namePtr), ino: ino, type: type, bridgeCookie: cookie)
        return cont ? 0 : 1
    }

// MARK: - Shared helpers

enum NTFSVolumeSupport {
    /// The volume's identity UUID: derived from the durable 64-bit NTFS boot-sector
    /// serial when present, else a synthesized label+size fallback. The serial is immutable,
    /// so identity survives relabels and stays distinct between independently-formatted
    /// same-label/same-size volumes. (A block-level clone copies the serial, so clones share
    /// identity.) Mirrors xlinuxfs's native-fs-UUID approach.
    static func volumeUUID(serial: UInt64, label: String, sizeBytes: UInt64) -> UUID {
        guard serial != 0 else { return stableUUID(label: label, sizeBytes: sizeBytes) }
        var u = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            let byte = UInt8(truncatingIfNeeded: serial >> (8 * UInt64(i)))
            u[i] = byte
            u[8 + i] = byte ^ 0x4E          // 'N' — deterministic high half
        }
        u[6] = (u[6] & 0x0F) | 0x40         // version-4 shape
        u[8] = (u[8] & 0x3F) | 0x80         // variant
        return UUID(uuid: (u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]))
    }

    static func stableUUID(label: String, sizeBytes: UInt64) -> UUID {
        var bytes = Array("NTFS-3G:\(label):\(sizeBytes)".utf8)
        var u = [UInt8](repeating: 0, count: 16)
        for (i, b) in bytes.enumerated() { u[i % 16] = u[i % 16] &+ b &+ UInt8(i & 0xff) }
        bytes.removeAll()
        u[6] = (u[6] & 0x0F) | 0x40
        u[8] = (u[8] & 0x3F) | 0x80
        return UUID(uuid: (u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]))
    }
}
