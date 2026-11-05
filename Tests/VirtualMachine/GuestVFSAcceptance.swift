import Foundation
import CryptoKit
import Darwin
import DiskArbitration
import IOKit

private struct Refusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct CommandTimeout: LocalizedError {
    let pid: Int32
    var errorDescription: String? { "系统命令超时，已仅向该命令PID \(pid)发送TERM；退出状态未知，保留现场且跳过全部分离清理" }
}

private struct Binding: Equatable, Codable {
    let device: String
    let media: UInt64
    let whole: UInt64
}

private struct Mount: Equatable, Codable {
    let type: String
    let source: String
    let path: String
    let identity: String
    let owner: UInt32
    let readOnly: Bool
}

@main enum GuestVFSAcceptance {
    static func main() {
        #if COMMAND_REGRESSION
        if CommandLine.arguments == [CommandLine.arguments[0], "--命令回归"] {
            do { try commandRegression(); exit(0) }
            catch { print("普通文件命令回归失败：\(error.localizedDescription)"); exit(1) }
        }
        #endif
        if CommandLine.arguments.count != 3 {
            print("用法：WriteFlowGuestAcceptance <64或128MiB空白NTFS模板文件> <模板SHA256>\n仅在macOS虚拟机普通用户中执行。工具不会安装应用、调用挂载/卸载、配置服务或修改系统权限；挂载动作须使用正式应用GUI。")
            exit(CommandLine.arguments.contains("--help") ? 0 : 64)
        }
        let model = systemString("hw.model")
        var virtual: Int32 = 0, size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.hv_vmm_present", &virtual, &size, nil, 0)
        guard (model.hasPrefix("VirtualMac") || virtual == 1), geteuid() >= 501 else {
            print("拒绝运行：必须在可确认的macOS虚拟机内以普通用户执行，不能在宿主或root账户运行。")
            exit(77)
        }
        let template = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let expected = CommandLine.arguments[2].lowercased()
        let identifier = UUID().uuidString
        let run = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NTFSWriteFlow/虚拟机验收/\(identifier)")
        let image = run.appendingPathComponent("本轮新建NTFS.img")
        var binding: Binding?, passed: [String] = [], observed: [Mount] = []
        var error: String?, detached = false, payloadSHA256 = "", imageSHA256 = "", finalImageSHA256 = ""
        var timedOutPID: Int32?
        do {
            try require(expected.count == 64 && expected.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "模板SHA256格式无效")
            var status = stat()
            try require(lstat(template.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid(), "模板必须是当前用户拥有的普通文件，不能是设备或符号链接")
            try require([Int64(64 * 1024 * 1024), Int64(128 * 1024 * 1024)].contains(status.st_size), "仅允许64或128MiB模板")
            try require(try hash(template) == expected, "模板SHA256与显式输入不符")
            let source = try FileHandle(forReadingFrom: template)
            let boot = try source.read(upToCount: 512) ?? Data()
            try source.close()
            try require(boot.count == 512 && String(decoding: boot[3..<11], as: UTF8.self) == "NTFS    ", "模板不是预期NTFS原始文件")
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: template, to: image)
            try require(try hash(image) == expected, "客体新副本摘要不一致")
            passed.append("客体内创建全新普通文件镜像，模板身份及摘要匹配")
            let attached = try command("/usr/bin/hdiutil", ["attach", "-nomount", "-nobrowse", "-plist", image.path], run: run)
            let names = try deviceEntries(dictionary(attached))
            try require(names.count == 1, "本轮原始镜像必须恰好映射一个设备")
            binding = try verify(image: image, device: names[0], bytes: status.st_size, expected: nil, run: run)
            passed.append("hdiutil新映射、虚拟File介质、容量与两层登记ID真实核验")
            print("证据目录：\(run.path)\n本轮设备：\(names[0])；只在应用里选择这一设备。")
            try prompt("先在正式应用GUI配置所需服务/扩展，选择本轮设备执行【只读挂载】；界面明确成功后按回车。")
            let firstRO = try ownedMount(binding!, image: image, bytes: status.st_size, readOnly: true, run: run)
            observed.append(firstRO)
            try denyWrite(firstRO.path, name: "只读拒写-\(identifier)")
            passed.append("GUI发起后内核真实只读挂载，创建按EROFS拒绝")
            try prompt("通过正式应用GUI【卸载此卷】，界面明确成功后按回车。")
            try require(try mounts(for: binding!.device).isEmpty, "GUI只读卸载后内核仍有挂载")
            _ = try verify(image: image, device: binding!.device, bytes: status.st_size, expected: binding, run: run)
            try require(try hash(image) == expected, "初次只读周期改变了完整镜像摘要")
            passed.append("正常只读卸载，原镜像完整摘要未变")
            try prompt("在正式应用GUI对同一设备执行【读写挂载】，界面明确成功后按回车。")
            let writable = try ownedMount(binding!, image: image, bytes: status.st_size, readOnly: false, run: run)
            observed.append(writable)
            let directory = URL(fileURLWithPath: writable.path).appendingPathComponent("中文验收-\(identifier)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("持久化.bin")
            let content = Data((0..<65_573).map { UInt8($0 % 251) })
            let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            payloadSHA256 = digest
            try content.write(to: file, options: .withoutOverwriting)
            let saved = try FileHandle(forUpdating: file)
            try saved.synchronize(); try saved.close()
            try require(try hash(file) == digest, "真实VFS写入同步后复读不一致")
            passed.append("真实VFS中文目录与65,573字节文件写入、同步和SHA256复读")
            let busy = try FileHandle(forReadingFrom: file)
            do {
                try prompt("工具正持有本轮文件。现在在GUI尝试卸载；须观察到占用失败并截图，确认后按回车，尚未关闭文件句柄。")
                let retained = try ownedMount(binding!, image: image, bytes: status.st_size, readOnly: false, run: run)
                try require(retained == writable, "占用卸载失败后原挂载实例发生变化")
                try require(try hash(file) == digest, "占用拒绝后文件内容改变")
            } catch { try? busy.close(); throw error }
            try busy.close()
            passed.append("持有真实打开文件时，GUI尝试卸载后VFS实例与内容仍保持；GUI错误另留截图")
            try prompt("文件句柄现已关闭。请在GUI正常卸载，确认没有收尾错误后按回车。")
            try require(try mounts(for: binding!.device).isEmpty, "读写卸载后内核仍有挂载")
            _ = try verify(image: image, device: binding!.device, bytes: status.st_size, expected: binding, run: run)
            let afterRW = try hash(image)
            imageSHA256 = afterRW
            passed.append("关闭占用后正常卸载，内核挂载消失；helper收尾状态由GUI与客体日志独立确认")
            try prompt("再次通过GUI【只读挂载】同一设备，明确成功后按回车。")
            let reopened = try ownedMount(binding!, image: image, bytes: status.st_size, readOnly: true, run: run)
            observed.append(reopened)
            let reread = URL(fileURLWithPath: reopened.path).appendingPathComponent(directory.lastPathComponent).appendingPathComponent("持久化.bin")
            try require(try hash(reread) == digest, "真实卸载重挂后文件SHA256不一致")
            try denyWrite(reopened.path, name: "重挂只读拒写-\(identifier)")
            passed.append("真实只读重挂后文件SHA256一致且继续EROFS拒写")
            try prompt("最后在GUI正常卸载，确认成功后按回车；工具随后仅正常分离本轮自有镜像。")
            try require(try mounts(for: binding!.device).isEmpty, "最后卸载后仍有挂载")
            _ = try verify(image: image, device: binding!.device, bytes: status.st_size, expected: binding, run: run)
            try require(try hash(image) == afterRW, "只读重挂周期改变了镜像摘要")
            _ = try command("/usr/bin/hdiutil", ["detach", binding!.device], run: run)
            try require(try mappedDevices(image: image, run: run).isEmpty, "正常分离后本轮镜像仍有映射")
            detached = true
            finalImageSHA256 = try hash(image)
            try require(finalImageSHA256 == afterRW, "正常分离后的最终刷新改变了镜像摘要")
            try require(try hash(template) == expected, "输入模板摘要发生变化")
            passed.append("只读周期完整镜像不变，正常分离后映射为零且最终镜像摘要一致，输入模板未变")
        } catch let failure {
            error = failure.localizedDescription
            timedOutPID = (failure as? CommandTimeout)?.pid
        }
        if timedOutPID == nil, !detached, FileManager.default.fileExists(atPath: image.path) {
            do {
                let devices = try mappedDevices(image: image, run: run)
                if devices.isEmpty { detached = true }
                else if devices.count == 1 {
                    let length = try FileManager.default.attributesOfItem(atPath: image.path)[.size] as? NSNumber
                    _ = try verify(image: image, device: devices[0], bytes: length?.int64Value ?? 0, expected: binding, run: run)
                    try require(try mounts(for: devices[0]).isEmpty, "失败后仍有挂载，保留应用和镜像，不代替GUI卸载")
                    _ = try command("/usr/bin/hdiutil", ["detach", devices[0]], run: run)
                    detached = try mappedDevices(image: image, run: run).isEmpty
                }
            } catch let cleanup {
                error = (error ?? "") + "；清理未确认：" + cleanup.localizedDescription
                timedOutPID = (cleanup as? CommandTimeout)?.pid
            }
        }
        let report: [String: Any] = ["结果": error == nil ? "通过" : "失败", "客体型号": model,
            "客体系统": ProcessInfo.processInfo.operatingSystemVersionString, "通过项": passed,
            "错误": error ?? "", "本轮镜像已正常分离": detached, "镜像": image.path,
            "输入模板SHA256": expected, "写入文件SHA256": payloadSHA256, "读写卸载后镜像SHA256": imageSHA256,
            "最终分离后镜像SHA256": finalImageSHA256, "超时命令PID": timedOutPID.map(String.init) ?? "", "因超时保留现场": timedOutPID != nil,
            "绑定": binding.map { ["设备": $0.device, "介质登记ID": String($0.media), "整盘登记ID": String($0.whole)] } ?? [:],
            "内核挂载观察": observed.map { ["类型": $0.type, "来源": $0.source, "路径": $0.path, "实例": $0.identity, "所有者": String($0.owner), "只读": String($0.readOnly)] },
            "范围": "仅本轮新建镜像的真实GUI触发/VFS文件操作；不直接调用C回调或mount/unmount，不自动配置权限。GUI错误与系统批准须另留截图；不代表实体盘、掉电或全部软件兼容。"]
        if FileManager.default.fileExists(atPath: run.path) {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: run.appendingPathComponent("结果.json"), options: .withoutOverwriting)
            } catch let recording { error = (error ?? "") + "；结果记录失败：" + recording.localizedDescription }
        }
        print(error == nil ? "本轮VFS检查通过，证据：\(run.path)" : "本轮未通过：\(error!)\n保留证据：\(run.path)")
        exit(error == nil ? 0 : 1)
    }

    private static func prompt(_ message: String) throws {
        print("\n\(message)")
        try require(readLine() != nil, "需要客体终端交互；SSH请使用-t，不能在无输入的后台盲跑")
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Refusal(message: message) } }
    private static func hash(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Refusal(message: "系统未返回有效属性列表") }
        return value
    }
    private static func command(_ executable: String, _ arguments: [String], run: URL, limit: TimeInterval = 45) throws -> Data {
        let process = Process()
        let errors = run.appendingPathComponent("系统命令-\(UUID().uuidString).log")
        let output = errors.appendingPathExtension("stdout")
        try Data().write(to: errors, options: .withoutOverwriting)
        try Data().write(to: output, options: .withoutOverwriting)
        let diagnostic = try FileHandle(forWritingTo: errors)
        let standardOutput = try FileHandle(forWritingTo: output)
        defer { try? diagnostic.close(); try? standardOutput.close() }
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = standardOutput; process.standardError = diagnostic; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while true {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { process.terminate() }
                let timeout = CommandTimeout(pid: process.processIdentifier)
                try? Data(timeout.localizedDescription.utf8).write(to: errors.appendingPathExtension("超时"), options: .withoutOverwriting)
                throw timeout
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try require(process.terminationStatus == 0, "系统命令失败（\(process.terminationStatus)）：\(String(decoding: try Data(contentsOf: errors), as: UTF8.self).prefix(500))")
        return try Data(contentsOf: output)
    }
    private static func mappedDevices(image: URL, run: URL) throws -> [String] {
        try mappedDevices(in: dictionary(command("/usr/bin/hdiutil", ["info", "-plist"], run: run)), image: image)
    }
    private static func mappedDevices(in listing: [String: Any], image: URL) throws -> [String] {
        guard let images = listing["images"] as? [[String: Any]] else { throw Refusal(message: "镜像清单结构未知，不能视为映射为零") }
        var matches: [[String: Any]] = []
        for entry in images {
            guard let path = entry["image-path"] as? String else { throw Refusal(message: "镜像清单缺失路径，不能视为映射为零") }
            if path == image.path { matches.append(entry) }
        }
        try require(matches.count <= 1, "镜像清单包含重复身份")
        return try matches.first.map(deviceEntries) ?? []
    }
    private static func deviceEntries(_ listing: [String: Any]) throws -> [String] {
        guard let entities = listing["system-entities"] as? [[String: Any]], !entities.isEmpty else { throw Refusal(message: "镜像设备清单结构未知或为空") }
        return try entities.map {
            guard let device = $0["dev-entry"] as? String, device.range(of: #"^/dev/disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil else { throw Refusal(message: "镜像设备条目无效") }
            return device
        }
    }
    #if COMMAND_REGRESSION
    private static func commandRegression() throws {
        for (major, minor, readOnly, expected) in [(13, 0, true, "macfuse"), (15, 3, true, "macfuse"),
            (15, 4, true, "ntfs"), (15, 4, false, "blntfs"), (26, 0, true, "ntfs"), (26, 3, true, "ntfs"),
            (26, 3, false, "blntfs"), (26, 4, true, "blntfs")] {
            try require(expectedFileSystemType(readOnly: readOnly,
                version: .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) == expected,
                "客体验收器必须分辨原生RO与FSKit RW，不能以错误后端代替")
        }
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("WriteFlow-普通文件命令回归-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let normal = try command("/bin/sh", ["-c", "printf '普通成功'"], run: run, limit: 2)
        try require(String(decoding: normal, as: UTF8.self) == "普通成功", "正常命令输出不符")
        for script in ["trap '' TERM; /bin/sleep 2", "trap 'exit 0' TERM; while :; do :; done"] {
            let start = ProcessInfo.processInfo.systemUptime
            var timeout: CommandTimeout?
            do { _ = try command("/bin/sh", ["-c", script], run: run, limit: 0.15) }
            catch let error as CommandTimeout { timeout = error }
            try require(timeout != nil && ProcessInfo.processInfo.systemUptime - start < 1.5, "忽略TERM或TERM后退出0不能视为正常成功，且必须有界返回")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let inherited = try command("/bin/sh", ["-c", "(/bin/sleep 2) & printf '后代持输出'; exit 0"], run: run, limit: 1)
        try require(String(decoding: inherited, as: UTF8.self) == "后代持输出" && ProcessInfo.processInfo.systemUptime - start < 1.5, "后代继承stdout不能阻止父命令返回")
        let image = run.appendingPathComponent("普通文件占位")
        try require(try mappedDevices(in: ["images": []], image: image).isEmpty, "有效空清单必须可以确认映射为零")
        try require(try mappedDevices(in: ["images": [["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk999"]]]]], image: image) == ["/dev/disk999"], "有效清单解析不符")
        let malformed: [[String: Any]] = [[:], ["images": "错型"], ["images": [[:]]],
            ["images": [["image-path": image.path]]],
            ["images": [["image-path": image.path, "system-entities": []]]],
            ["images": [["image-path": image.path, "system-entities": [["dev-entry": 1]]]]]]
        for listing in malformed {
            var rejected = false
            do { _ = try mappedDevices(in: listing, image: image) } catch { rejected = true }
            try require(rejected, "未知镜像清单不能视为分离成功")
        }
        Thread.sleep(forTimeInterval: 2.1)
        print("普通文件命令回归通过：后端类型8项、正常输出、忽略TERM有界超时、TERM退出0仍失败、后代持stdout不阻塞、有效清单2项及未知结构6项；无设备操作。证据：\(run.path)")
    }
    #endif
    private static func verify(image: URL, device: String, bytes: Int64, expected: Binding?, run: URL) throws -> Binding {
        try require(device.range(of: #"^/dev/disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil, "设备名无效")
        try require(try mappedDevices(image: image, run: run) == [device], "设备不再属于本轮唯一镜像映射")
        guard let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, device), let whole = DADiskCopyWholeDisk(disk) else { throw Refusal(message: "无法保留当前介质对象") }
        let media = DADiskCopyIOMedia(disk), wholeMedia = DADiskCopyIOMedia(whole)
        defer { if media != 0 { IOObjectRelease(media) }; if wholeMedia != 0 { IOObjectRelease(wholeMedia) } }
        var mediaID: UInt64 = 0, wholeID: UInt64 = 0
        let properties = IORegistryEntrySearchCFProperty(wholeMedia, kIOServicePlane, "Protocol Characteristics" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any]
        let description = DADiskCopyDescription(disk) as? [String: Any]
        try require(media != 0 && wholeMedia != 0 && IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS && IORegistryEntryGetRegistryEntryID(wholeMedia, &wholeID) == KERN_SUCCESS,
                    "介质登记身份不可确认")
        try require(properties?["Physical Interconnect"] as? String == "Virtual Interface" && properties?["Physical Interconnect Location"] as? String == "File", "只允许虚拟File镜像，拒绝实体盘")
        try require((description?[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value == bytes, "镜像容量与原文件不一致")
        let result = Binding(device: device, media: mediaID, whole: wholeID)
        try require(expected == nil || result == expected, "原介质已移除或登记身份变化")
        return result
    }
    private static func mounts(for device: String) throws -> [Mount] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { throw Refusal(message: "无法读取内核挂载表") }
        return (0..<Int(count)).compactMap { index in
            var value = entries[index]
            func text<T>(_ field: inout T) -> String { withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            let source = text(&value.f_mntfromname)
            guard source == device else { return nil }
            return Mount(type: text(&value.f_fstypename), source: source, path: text(&value.f_mntonname),
                identity: "\(value.f_fsid.val.0):\(value.f_fsid.val.1)", owner: value.f_owner, readOnly: value.f_flags & UInt32(MNT_RDONLY) != 0)
        }
    }
    private static func ownedMount(_ binding: Binding, image: URL, bytes: Int64, readOnly: Bool, run: URL) throws -> Mount {
        _ = try verify(image: image, device: binding.device, bytes: bytes, expected: binding, run: run)
        let values = try mounts(for: binding.device)
        try require(values.count == 1, "GUI动作后未找到唯一真实VFS挂载；请保存应用原始错误，不用C回调替代")
        let value = values[0]
        let type = expectedFileSystemType(readOnly: readOnly)
        let prefix = "/private/var/db/com.blteam.ntfsworkbench.mounts/\(geteuid())/"
        let parts = value.path.hasPrefix(prefix) ? value.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init) : []
        try require(value.type == type && value.owner == 0 && value.readOnly == readOnly && parts.count == 2 && parts.last == "volume" && UUID(uuidString: parts.first ?? "")?.uuidString == parts.first,
                    "挂载类型、root所有权、只读模式或本应用私有凭据路径不符")
        return value
    }

    private static func expectedFileSystemType(readOnly: Bool, version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let fsKitSystem = version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4)
        let needsNativeReadOnly = version.majorVersion < 26 || (version.majorVersion == 26 && version.minorVersion < 4)
        return fsKitSystem ? (readOnly && needsNativeReadOnly ? "ntfs" : "blntfs") : "macfuse"
    }
    private static func denyWrite(_ path: String, name: String) throws {
        let target = URL(fileURLWithPath: path).appendingPathComponent(name).path
        let file = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600), error = errno
        if file >= 0 { close(file); _ = unlink(target) }
        try require(file < 0 && error == EROFS, "只读VFS未按EROFS拒绝创建")
    }
    private static func systemString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "未知" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "未知" }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
