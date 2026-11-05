import Foundation

enum PrivilegedMountConfiguration {
    static let machServiceName = "com.blteam.ntfsworkbench.mount-helper"
    static let daemonPlistName = "com.blteam.ntfsworkbench.mount-helper.plist"
    static let helperIdentifier = "com.blteam.ntfsworkbench.mount-helper"
    static let namespace = "/private/var/db/com.blteam.ntfsworkbench.mounts"
    static let clientRequirement = "anchor apple generic and identifier \"com.blteam.ntfsworkbench\" and certificate leaf[subject.OU] = \"ALV8Y54GCY\""
    static let helperRequirement = "anchor apple generic and identifier \"com.blteam.ntfsworkbench.mount-helper\" and certificate leaf[subject.OU] = \"ALV8Y54GCY\""

    // 仅供应用识别候选路径；助手仍独立核验目录、所有权、介质与挂载实例。
    static func token(mountPoint: String, userID: UInt32) -> String? {
        let prefix = namespace + "/\(userID)/"
        guard mountPoint.hasPrefix(prefix) else { return nil }
        let parts = mountPoint.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "volume",
              let value = UUID(uuidString: String(parts[0])), value.uuidString == String(parts[0]) else { return nil }
        return value.uuidString
    }
}

struct PrivilegedMountRequest: Codable, Sendable {
    let deviceID: String
    let mediaRegistryID: UInt64
    let wholeMediaRegistryID: UInt64
    let mediaByteCount: Int64
    let readOnly: Bool
}

// 后端仅由可信服务按系统版本和访问模式选择，XPC请求不能指定。
enum PrivilegedMountBackend: String, Codable, Sendable {
    case fsKit, macFUSE, nativeReadOnly

    static func select(readOnly: Bool, on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Self {
        if version.majorVersion < 15 || (version.majorVersion == 15 && version.minorVersion < 4) { return .macFUSE }
        let needsNativeReadOnly = version.majorVersion < 26 || (version.majorVersion == 26 && version.minorVersion < 4)
        return readOnly && needsNativeReadOnly ? .nativeReadOnly : .fsKit
    }

    var fileSystemType: String {
        switch self { case .fsKit: "blntfs"; case .macFUSE: "macfuse"; case .nativeReadOnly: "ntfs" }
    }
}

struct PrivilegedMountResult: Codable, Sendable {
    let token: String
    let mountPoint: String
    let deviceID: String
    let mediaRegistryID: UInt64
    let wholeMediaRegistryID: UInt64
    let fileSystemIdentity: String
    let readOnly: Bool
    var backend: PrivilegedMountBackend?
}

struct PrivilegedEjectRequest: Codable, Sendable {
    let deviceID: String
    let wholeDiskID: String
    let mediaRegistryID: UInt64
    let wholeMediaRegistryID: UInt64
    let mediaByteCount: Int64
    let wholeMediaByteCount: Int64
}

@objc protocol PrivilegedMountProtocol {
    func mountLegacy(_ request: Data, handle: FileHandle, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func mount(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func unmount(_ token: String, handle: FileHandle, withReply reply: @escaping @Sendable (String?) -> Void)
    func prepareEject(_ request: Data, handles: [FileHandle], withReply reply: @escaping @Sendable (String?) -> Void)
    func mountedVolumes(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

