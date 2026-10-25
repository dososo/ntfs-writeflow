import Foundation
import CryptoKit
import Darwin
import DiskArbitration

// 不接受设备参数，只创建并操作本次生成的普通文件镜像。
@main enum MountServiceIntegration {
    static func main() async {
        guard CommandLine.arguments.count == 1, AppCapabilities.directMountEnabled else {
            print("服务集成测试未运行：不接受外部参数，且需先通过扩展门禁并开放生产挂载入口。")
            exit(2)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let run = root.appendingPathComponent("build/服务集成验证/\(UUID().uuidString)")
        let image = run.appendingPathComponent("全新测试镜像.img")
        let service = DiskService()
        var device: String?
        var mediaID: UInt64?
        var checks: [String] = []
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try Data().write(to: image, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: image)
            try handle.truncate(atOffset: 128 * 1024 * 1024)
            try handle.close()
            _ = try command(root.appendingPathComponent("build/engine/arm64/ntfsprogs/mkntfs").path,
                ["-F", "-Q", "-s", "512", "-L", "WRITEFLOW_SERVICE", image.path], log: run.appendingPathComponent("格式化.log"))
            let pristine = try hash(image)
            let attached = try command("/usr/bin/hdiutil", ["attach", "-nomount", "-nobrowse", "-plist", image.path],
                log: run.appendingPathComponent("附加.log"))
            let plist = try dictionary(attached)
            let entries = (plist["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            try require(entries.count == 1, "本次镜像必须只有一个设备")
            device = entries[0]
            let identifier = String(entries[0].dropFirst(5))
            try require(entries[0].hasPrefix("/dev/") && VolumeRecord.validDeviceID(identifier), "附加设备路径无效")
            try verifyMapping(image, device: entries[0])
            guard let initial = try await service.record(identifier) else { throw failureError("读取测试介质失败") }
            try require(initial.mediaByteCount == 128 * 1024 * 1024 && initial.mountPoint == nil,
                "只允许新建、正确容量且未挂载的测试镜像")
            try require(initial.canOfferMount, "镜像未满足生产挂载保护条件；不伪造状态或放宽保护")
            mediaID = initial.mediaRegistryID
            if let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, identifier),
               let description = DADiskCopyDescription(disk) as? [String: Any] {
                let values: [String: String] = [
                    "diskutil内部属性": String(describing: initial.isInternal),
                    "DA内部属性": String(describing: description[kDADiskDescriptionDeviceInternalKey as String]),
                    "DA设备名": String(describing: description[kDADiskDescriptionMediaBSDNameKey as String]),
                    "DA介质容量": String(describing: description[kDADiskDescriptionMediaSizeKey as String]),
                    "稳定介质容量": String(initial.mediaByteCount)
                ]
                try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                    .write(to: run.appendingPathComponent("绑定来源诊断.json"))
            }
            checks.append("新建镜像与生产介质保护核验")

            try await service.mount(initial, readOnly: true)
            let readOnly = try await mounted(service, identifier: identifier, mediaID: mediaID!, readOnly: true)
            checks.append("生产服务只读挂载及内核回读")
            let refused = URL(fileURLWithPath: readOnly.mountPoint!).appendingPathComponent("不应创建.txt")
            let descriptor = open(refused.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            let error = errno
            if descriptor >= 0 { close(descriptor) }
            try require(descriptor < 0 && error == EROFS, "只读挂载未按 EROFS 拒绝创建")
            checks.append("可写镜像上的只读挂载拒写")
            do {
                try await service.mount(initial, readOnly: false)
                throw failureError("重复挂载没有被拒绝")
            } catch let error as DiskOperationError {
                try require(!error.message.contains("重复挂载没有被拒绝"), error.message)
            }
            let unchanged = try await mounted(service, identifier: identifier, mediaID: mediaID!, readOnly: true)
            try require(unchanged.mountedFileSystem == readOnly.mountedFileSystem, "被拒绝的重复挂载改变了原挂载")
            checks.append("重复挂载失败且原状态未变")
            try await service.unmount(readOnly)
            try require(try await service.record(identifier)?.mountPoint == nil, "funmount 后仍有挂载点")
            try require(try hash(image) == pristine, "只读周期改变了镜像内容")
            checks.append("funmount 正常卸载与只读镜像哈希不变")

            guard let next = try await service.record(identifier) else { throw failureError("再次读取测试介质失败") }
            try await service.mount(next, readOnly: false)
            let writable = try await mounted(service, identifier: identifier, mediaID: mediaID!, readOnly: false)
            let directory = URL(fileURLWithPath: writable.mountPoint!).appendingPathComponent("服务中文验证")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("持久化.bin")
            let data = Data((0..<65_573).map { UInt8($0 % 251) })
            try data.write(to: file)
            let openFile = try FileHandle(forUpdating: file)
            try openFile.synchronize()
            try require(try Data(contentsOf: file) == data, "服务读写内容不一致")
            checks.append("生产服务读写挂载、中文目录、文件同步读取")
            do {
                try await service.unmount(writable)
                try openFile.close()
                throw failureError("占用文件时卸载未被拒绝")
            } catch let error as DiskOperationError {
                try openFile.close()
                try require(error.message.contains("卷未卸载（\(EBUSY)）"), "占用场景应返回 EBUSY，实际为：\(error.message)")
            }
            let stillMounted = try await mounted(service, identifier: identifier, mediaID: mediaID!, readOnly: false)
            try require(stillMounted.mountedFileSystem == writable.mountedFileSystem, "卸载失败后原挂载实例变化")
            checks.append("占用时卸载失败且保留原挂载状态")
            try await service.unmount(stillMounted)
            guard let finalRecord = try await service.record(identifier) else { throw failureError("读取卸载后状态失败") }
            try require(finalRecord.mountPoint == nil, "读写卷卸载未确认")
            try await service.mount(finalRecord, readOnly: true)
            let reopened = try await mounted(service, identifier: identifier, mediaID: mediaID!, readOnly: true)
            let reopenedFile = URL(fileURLWithPath: reopened.mountPoint!).appendingPathComponent("服务中文验证/持久化.bin")
            try require(try Data(contentsOf: reopenedFile) == data, "重挂载后文件内容不一致")
            try await service.unmount(reopened)
            checks.append("服务卸载后只读重挂载内容持久化")
            try verifyMapping(image, device: device!)
            _ = try command("/usr/bin/hdiutil", ["detach", device!], log: run.appendingPathComponent("分离.log"))
            device = nil
            let offline = try command(root.appendingPathComponent("build/engine/arm64/ntfsprogs/ntfscat").path,
                [image.path, "/服务中文验证/持久化.bin"], log: run.appendingPathComponent("离线复读.log"))
            try require(offline == data, "离线复读内容不一致")
            checks.append("分离后同引擎独立命令复读")
        } catch { failure = error.localizedDescription }

        var cleanup = device == nil
        if let device {
            do {
                try verifyMapping(image, device: device)
                let identifier = String(device.dropFirst(5))
                if let current = try await service.record(identifier), current.mountPoint != nil {
                    try require(current.mediaRegistryID == mediaID && current.isMountedByWriteFlow,
                        "清理时介质或挂载者变化，停止自动清理")
                    try await service.unmount(current)
                }
                _ = try command("/usr/bin/hdiutil", ["detach", device], log: run.appendingPathComponent("失败后分离.log"))
                cleanup = true
            } catch { failure = (failure ?? "") + "；清理未完成：" + error.localizedDescription }
        }
        let report: [String: Any] = ["结果": failure == nil ? "通过" : "失败", "已通过": checks,
            "错误": failure ?? "", "测试设备已分离": cleanup, "证据目录": run.path,
            "边界": "仅新建镜像；同一生产服务；未验证物理介质，ntfscat仍为同一引擎。"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: run.appendingPathComponent("结果.json"))
            print(String(decoding: data, as: UTF8.self))
        }
        exit(failure == nil ? 0 : 1)
    }

    static func mounted(_ service: DiskService, identifier: String, mediaID: UInt64, readOnly: Bool) async throws -> VolumeRecord {
        guard let record = try await service.record(identifier), record.mediaRegistryID == mediaID,
              record.isMountedByWriteFlow, record.mountedFileSystem?.ownerID == geteuid(),
              record.access == (readOnly ? .readOnly : .readWrite) else {
            throw failureError("服务返回后内核挂载状态不符")
        }
        return record
    }

    static func verifyMapping(_ image: URL, device: String) throws {
        let info = try dictionary(command("/usr/bin/hdiutil", ["info", "-plist"]))
        let images = info["images"] as? [[String: Any]] ?? []
        try require(images.contains { item in
            item["image-path"] as? String == image.path
                && (item["system-entities"] as? [[String: Any]] ?? []).contains { $0["dev-entry"] as? String == device }
        }, "当前设备不再属于本次新建镜像")
    }

    static func command(_ executable: String, _ arguments: [String], log: URL? = nil) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let log { try (Data("退出码：\(process.terminationStatus)\n".utf8) + error).write(to: log) }
        try require(process.terminationStatus == 0,
            "命令失败 \(executable)（\(process.terminationStatus)）：\(String(decoding: error, as: UTF8.self))")
        return data
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw failureError("系统未返回有效属性列表")
        }
        return value
    }

    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw failureError(message) }
    }
    static func failureError(_ message: String) -> DiskOperationError { DiskOperationError(message: message) }
}
