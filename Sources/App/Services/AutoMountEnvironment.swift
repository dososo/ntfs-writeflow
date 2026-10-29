import Foundation
import FSKit
import Darwin

struct AutoMountEnvironment: Sendable {
    let isClear: Bool
    let reason: String

    static func classify(filesystems: [String], extensions: [String], loaded: [String], modules: [String]) -> Self {
        let markers = ["ntfs", "ufsd", "paragon", "tuxera", "fuse", "highpoint"]
        let candidates = filesystems + extensions + loaded.filter { !$0.hasPrefix("com.apple.") }
        if candidates.contains(where: { value in markers.contains { value.lowercased().contains($0) } }) {
            return Self(isClear: false, reason: "发现已安装或加载的第三方磁盘驱动，自动挂载已暂停；不会卸载或禁用其他驱动。")
        }
        if !filesystems.isEmpty || !extensions.isEmpty || !loaded.filter({ !$0.hasPrefix("com.apple.") }).isEmpty ||
            modules.contains(where: { !$0.hasPrefix("com.apple.") && $0 != "com.blteam.ntfsworkbench.filesystem" }) {
            return Self(isClear: false, reason: "存在无法确认用途的第三方文件系统或内核扩展，竞争状态未知。")
        }
        return Self(isClear: true, reason: "公开驱动登记、安装目录和已加载列表未发现竞争；每次操作仍核验实际挂载。")
    }

    static func load() async -> Self {
        do {
            let modules = try await FSClient.shared.installedExtensions
            let identifiers = modules.map(\.bundleIdentifier)
            return await Task.detached {
                do {
                    let manager = FileManager.default
                    let fs = try manager.contentsOfDirectory(atPath: "/Library/Filesystems").filter { $0.hasSuffix(".fs") }
                    let kext = try manager.contentsOfDirectory(atPath: "/Library/Extensions").filter { $0.hasSuffix(".kext") }
                    let text = try query("/usr/sbin/kextstat", ["-l"])
                    guard let loaded = parseLoaded(text) else { return Self(isClear: false, reason: "无法完整识别已加载驱动清单，自动挂载已暂停。") }
                    let plugins = try query("/usr/bin/pluginkit", ["-m", "-A", "-D", "-p", "com.apple.fskit.fsmodule"])
                    guard let registered = parseRegistered(plugins) else {
                        return Self(isClear: false, reason: "无法完整识别已登记模块清单，自动挂载已暂停。")
                    }
                    return classify(filesystems: fs, extensions: kext, loaded: loaded, modules: identifiers + registered)
                } catch { return Self(isClear: false, reason: "无法完整查询驱动竞争状态，自动挂载已暂停。") }
            }.value
        } catch { return Self(isClear: false, reason: "无法查询文件系统扩展，自动挂载已暂停。") }
    }

    static func parseLoaded(_ text: String) -> [String]? {
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { continue }
            if first.allSatisfy(\.isNumber) {
                guard words.count >= 7, words[5].range(of: #"^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#,
                    options: .regularExpression) != nil else { return nil }
                result.append(words[5])
            } else if first != "Index" || !words.contains("Name") { return nil }
        }
        return result.isEmpty ? nil : result
    }

    static func parseRegistered(_ text: String) -> [String]? {
        let pattern = #"^\s*[+\-=!]?\s*([A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+)\((?:\(null\)|[^\r\n()]{1,128})\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        var result: [String] = []
        var summary: Int?
        for raw in text.split(separator: "\n") {
            let line = String(raw), range = NSRange(line.startIndex..., in: line)
            if let match = expression.firstMatch(in: line, range: range), let identifier = Range(match.range(at: 1), in: line) {
                result.append(String(line[identifier]))
            } else {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.count == 2, words[0].hasPrefix("("), words[1] == "plug-ins)",
                      let count = Int(words[0].dropFirst()), summary == nil else { return nil }
                summary = count
            }
        }
        if let summary, summary != result.count { return nil }
        return result
    }

    // 仅调用固定公开查询命令；fd非阻塞，deadline同时限制读取和进程等待。
    // 测试可传自有fixture；此函数不通过XPC暴露，也不在DA批准回调执行。
    static func query(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
                      maximumBytes: Int = 1_048_576) throws -> String {
        guard timeout > 0, maximumBytes > 0 else { throw queryError(EINVAL) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            throw queryError(EIO)
        }
        defer {
            // 不调用waitUntilExit；超时后的自有查询进程可异步结束，不阻塞UI或DA。
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
        }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(timeout))
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        var reachedEOF = false
        while true {
            guard clock.now < deadline else { throw queryError(ETIMEDOUT) }
            // 每轮读取有上限，持续输出也不能饿死deadline检查。
            for _ in 0..<16 where !reachedEOF {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard result.count <= maximumBytes - count else { throw queryError(EFBIG) }
                    result.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { reachedEOF = true; break }
                else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
                else { throw queryError(errno) }
            }
            if !process.isRunning && reachedEOF {
                guard process.terminationStatus == 0 else { throw queryError(EIO) }
                guard let text = String(data: result, encoding: .utf8) else { throw queryError(EILSEQ) }
                return text
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func queryError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
