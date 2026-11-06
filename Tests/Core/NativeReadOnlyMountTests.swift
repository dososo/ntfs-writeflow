import Foundation
import Darwin

@main enum NativeReadOnlyMountTests {
    static func main() throws {
        precondition(geteuid() != 0, "本回归只允许运行普通用户验证")
        var checks: [String] = []
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks.append(message) }
        func rejected(_ message: String, _ work: () throws -> Void) {
            do { try work(); fatalError(message) }
            catch is HelperFailure { checks.append(message) }
            catch { fatalError("非预期错误：\(error)") }
        }
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        for (major, minor, readOnly, expected): (Int, Int, Bool, PrivilegedMountBackend) in [
            (13, 0, true, .macFUSE), (15, 3, true, .macFUSE), (15, 4, true, .nativeReadOnly),
            (15, 7, true, .nativeReadOnly), (15, 4, false, .fsKit), (25, 0, true, .nativeReadOnly),
            (26, 0, true, .nativeReadOnly), (26, 3, true, .nativeReadOnly),
            (26, 0, false, .fsKit), (26, 3, false, .fsKit), (26, 4, true, .fsKit), (27, 2, false, .fsKit)] {
            check(PrivilegedMountBackend.select(readOnly: readOnly,
                on: .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) == expected,
                "后端只能由系统\(major).\(minor)与只读请求\(readOnly)派生")
        }
        for (major, minor, readOnly, expected) in [(15, 4, true, true), (15, 4, false, true),
            (26, 0, true, true), (26, 3, true, true), (26, 3, false, false), (26, 4, true, false)] {
            check(NativeReadOnlyMount.requiresBoundedCommand(readOnly: readOnly,
                on: .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) == expected,
                "\(major).\(minor)只读\(readOnly)的命令执行与未知保留采用有界策略\(expected)")
        }
        for (major, minor, expected) in [(13, 0, true), (15, 4, true), (26, 0, true), (26, 3, true), (26, 4, false)] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
            check(StorageBackend.requiresManagedMount(on: version) == expected,
                  "\(major).\(minor)所有请求统一受管/扫描\(expected)，不能因RW或raw可读写绕过旧RO未决票据")
        }
        let pending = HelperTicket(userID: 502, token: "ABCDEFAB-2222-4333-8444-555555555555",
            request: PrivilegedMountRequest(deviceID: "disk99s1", mediaRegistryID: 123, wholeMediaRegistryID: 122,
                mediaByteCount: 134_217_728, readOnly: true), backend: .nativeReadOnly)
        check(StorageBackend.requiresManagedMount(on: .init(majorVersion: 26, minorVersion: 3, patchVersion: 0)) &&
              !NativeReadOnlyMount.requiresBoundedCommand(readOnly: false, on: .init(majorVersion: 26, minorVersion: 3, patchVersion: 0)),
              "26.3下一次RW必须先经helper扫描，但RW命令与旧runner保持不变")
        rejected("26.3跨模式RW必须拒绝旧RO的跨UID同whole未决票据") {
            try HelperNamespace.requireNoPendingBridgeTicket(pending, wholeMediaRegistryID: 122)
        }
        let token = "ABCDEFAB-2222-4333-8444-555555555555"
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        let request = PrivilegedMountRequest(deviceID: "disk99s1", mediaRegistryID: 123,
            wholeMediaRegistryID: 122, mediaByteCount: 134_217_728, readOnly: true)
        let ticket = HelperTicket(userID: 501, token: token, request: request,
            fileSystemIdentity: "1:2", backend: .nativeReadOnly)
        func mounted(type: String = "ntfs", at: String? = nil, owner: UInt32 = 0, ro: Bool = true,
                     source: String = "/dev/disk99s1", identity: String = "1:2") -> MountedFileSystem {
            MountedFileSystem(type: type, source: source, mountPoint: at ?? path,
                identity: identity, ownerID: owner, isReadOnly: ro)
        }
        let expected = mounted()
        try NativeReadOnlyMount.verifyExpected(ticket: ticket, mounted: expected)
        try ManagedUnmount.verifyMount(ticket: ticket, expected: expected)
        check(PrivilegedMountEngine.matchesOwnedMount(ticket, path: path, mounted: expected),
              "原生RO需root私有路径与持久票据后端证明，正常卸载沿用严格门禁")
        let invocation = try NativeReadOnlyMount.invocation(request, userID: 501, token: token, on: version)
        check(invocation.0 == "/usr/sbin/diskutil" && invocation.1 == ["mount", "readOnly", "nobrowse", "-mountOptions",
            "nosuid,nodev,noowners", "-mountPoint", path, "disk99s1"], "固定原生命令不接受类型、额外选项、用户路径或FSKit介质私有选项")
        for minor in [0, 3] {
            let extended = try NativeReadOnlyMount.invocation(request, userID: 501, token: token,
                on: .init(majorVersion: 26, minorVersion: minor, patchVersion: 0))
            check(extended.0 == invocation.0 && extended.1 == invocation.1,
                  "26.\(minor)原生RO仍走同一固定系统命令，只有策略验证而非真实系统验收")
            let pending = HelperTicket(userID: 502, token: token, request: request, backend: .nativeReadOnly)
            if NativeReadOnlyMount.requiresBoundedCommand(readOnly: true,
                on: .init(majorVersion: 26, minorVersion: minor, patchVersion: 0)) {
                rejected("26.\(minor)原生RO建票据前拒绝跨UID同whole未决票据") {
                    try HelperNamespace.requireNoPendingBridgeTicket(pending, wholeMediaRegistryID: request.wholeMediaRegistryID)
                }
            } else { fatalError("26.0～26.3原生RO不能跳过未决扫描") }
        }
        for version in [OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)] {
            rejected("平台不适用不能选择原生RO") {
                _ = try NativeReadOnlyMount.invocation(request, userID: 501, token: token, on: version)
            }
        }
        let writable = PrivilegedMountRequest(deviceID: request.deviceID, mediaRegistryID: 123,
            wholeMediaRegistryID: 122, mediaByteCount: request.mediaByteCount, readOnly: false)
        rejected("读写请求不能经原生只读路由") {
            _ = try NativeReadOnlyMount.invocation(writable, userID: 501, token: token, on: version)
        }
        for (uid, value): (UInt32, String) in [(0, token), (.max, token), (501, "../其他")] {
            rejected("无效用户或token不能进入原生命令") {
                _ = try NativeReadOnlyMount.invocation(request, userID: uid, token: value, on: version)
            }
        }
        for invalid in [mounted(type: "blntfs"), mounted(type: "macfuse"), mounted(ro: false), mounted(owner: 501),
            mounted(at: "/Volumes/其他卷"), mounted(at: path + "/"), mounted(at: path.replacingOccurrences(of: "/501/", with: "/502/")),
            mounted(source: "/dev/disk99s2"), mounted(identity: "其他实例")] {
            rejected("原生RO错误类型、模式、所有者、路径、介质或实例拒绝") {
                try NativeReadOnlyMount.verifyExpected(ticket: ticket, mounted: invalid)
            }
        }
        for backend: PrivilegedMountBackend? in [nil, .fsKit, .macFUSE] {
            let invalid = HelperTicket(userID: 501, token: token, request: request, fileSystemIdentity: "1:2", backend: backend)
            check(!PrivilegedMountEngine.matchesOwnedMount(invalid, path: path, mounted: expected),
                  "缺失或错误后端票据不能接管原生NTFS")
            rejected("正常卸载也要求原生后端票据") { try ManagedUnmount.verifyMount(ticket: invalid, expected: expected) }
        }
        let wrongRequest = HelperTicket(userID: 501, token: token, request: writable, fileSystemIdentity: "1:2", backend: .nativeReadOnly)
        check(!PrivilegedMountEngine.matchesOwnedMount(wrongRequest, path: path, mounted: expected), "原生后端不能伪装读写请求")
        let rootTicket = HelperTicket(userID: 0, token: token, request: request, fileSystemIdentity: "1:2", backend: .nativeReadOnly)
        rejected("无效UID票据即便路径数字匹配也不能证明原生RO") {
            try NativeReadOnlyMount.verifyExpected(ticket: rootTicket, mounted: mounted(at: path.replacingOccurrences(of: "/501/", with: "/0/")))
        }
        let required = UInt32(MNT_RDONLY | MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE | MNT_IGNORE_OWNERSHIP)
        try NativeReadOnlyMount.verifyFlags(required | UInt32(MNT_LOCAL | MNT_NOATIME))
        checks.append("内核回读同时确认RO与四项安全标志，不只相信命令退出0")
        for flag in [MNT_RDONLY, MNT_NOSUID, MNT_NODEV, MNT_DONTBROWSE, MNT_IGNORE_OWNERSHIP] {
            rejected("缺少内核安全位\(flag)不能报挂载成功") { try NativeReadOnlyMount.verifyFlags(required & ~UInt32(flag)) }
        }
        let directory = "/private/tmp/WriteFlow-原生只读FD-\(UUID().uuidString)"
        precondition(mkdir(directory, 0o700) == 0)
        defer { precondition(rmdir(directory) == 0) }
        let fd = open(directory, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(fd >= 0)
        defer { close(fd) }
        rejected("真实自有普通目录FD不能冒充root挂载根") {
            try NativeReadOnlyMount.verifyDescriptor(fd, ticket: ticket, expected: expected)
        }
        rejected("无效FD不能绕过根路径检查") { try NativeReadOnlyMount.verifyDescriptor(-1, ticket: ticket, expected: expected) }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as! [String: Any]
        json.removeValue(forKey: "backend")
        let old = try JSONDecoder().decode(HelperTicket.self, from: JSONSerialization.data(withJSONObject: json))
        check(old.backend == nil && !old.matchesBackend(expected), "历史无backend票据可解码，但不能证明原生RO所有权")
        let oldBlntfs = mounted(type: "blntfs", ro: false)
        check(PrivilegedMountEngine.matchesOwnedMount(old, path: path, mounted: oldBlntfs),
              "旧blntfs只读失败票据仍可查询，不能因新增backend丢失恢复")
        try ManagedUnmount.verifyMount(ticket: old, expected: oldBlntfs)
        checks.append("旧blntfs模式不符挂载仍可通过严格凭据门禁正常卸载")
        let restored = try JSONDecoder().decode(HelperTicket.self, from: JSONEncoder().encode(ticket))
        try HelperNamespace.UnmountLease.verifyTicket(restored, expected: ticket)
        checks.append("后端证明随原票据可靠编码并参与租约一致性校验")
        rejected("旧票据不能替代新后端票据") { try HelperNamespace.UnmountLease.verifyTicket(old, expected: ticket) }
        json["backend"] = "未知后端"
        do {
            _ = try JSONDecoder().decode(HelperTicket.self, from: JSONSerialization.data(withJSONObject: json))
            fatalError("未知票据后端不能默认放行")
        } catch is DecodingError { checks.append("未知后端解码失败，不静默回退") }
        var client = try JSONSerialization.jsonObject(with: JSONEncoder().encode(writable)) as! [String: Any]
        client["backend"] = "nativeReadOnly"
        let clientRequest = try JSONDecoder().decode(PrivilegedMountRequest.self, from: JSONSerialization.data(withJSONObject: client))
        check(PrivilegedMountBackend.select(readOnly: clientRequest.readOnly, on: version) == .fsKit,
              "XPC额外backend字段不能改变读写后端选择")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["结果": "通过", "数量": checks.count,
            "检查": checks, "边界": "纯生产策略、持久票据转换、构造内核标志及真实自有普通目录FD拒绝；没有提权、挂载、卸载或设备操作。"],
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
