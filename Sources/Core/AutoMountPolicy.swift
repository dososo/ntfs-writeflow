import Foundation

enum AutoMountMode: String, Codable, CaseIterable, Sendable {
    case off, readOnly, readWrite
    var title: String {
        switch self { case .off: "关闭"; case .readOnly: "自动只读"; case .readWrite: "自动读写" }
    }
}

// 永久政策的匹配值；IORegistry身份仅用于本次接入，不能充当永久设备主键。
struct AutoMountFingerprint: Codable, Hashable, Sendable {
    let volumeUUID: String
    let mediaByteCount: Int64
    let deviceGUID: String?

    init?(volumeUUID: String, mediaByteCount: Int64, deviceGUID: String?) {
        let uuid = volumeUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !uuid.isEmpty, uuid.count <= 256, mediaByteCount > 0 else { return nil }
        let guid = deviceGUID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (guid?.count ?? 0) <= 256 else { return nil }
        self.volumeUUID = uuid
        self.mediaByteCount = mediaByteCount
        self.deviceGUID = guid?.isEmpty == false ? guid : nil
    }
    var permitsRememberedWrite: Bool { deviceGUID != nil }
}

struct AutoMountCandidate: Sendable {
    let volume: VolumeRecord
    let fingerprint: AutoMountFingerprint?
    let generation: UInt64
}

enum AutoMountCompetition: Sendable { case clear, conflict, unknown }

struct AutoMountContext: Sendable {
    var enabled: Bool
    var consoleUserActive: Bool
    var sessionUnlocked: Bool
    var extensionReady: Bool
    var helperReady: Bool
    var competition: AutoMountCompetition
}

enum AutoMountOutcome: Equatable, Sendable {
    case skipped(String), mounted(AutoMountMode), failed(String), unconfirmed
    var message: String {
        switch self {
        case .skipped(let reason): reason
        case .mounted(let mode): "已完成\(mode.title)，挂载身份及访问模式已核实。"
        case .failed(let reason): "自动挂载失败：\(reason)"
        case .unconfirmed: "操作后状态变化或未核实，请刷新；不会自动重试或强制清理。"
        }
    }
}

@MainActor final class AutoMountPolicyStore {
    private struct Rule: Codable { let fingerprint: AutoMountFingerprint; let mode: AutoMountMode }
    private struct Document: Codable { let version: Int; let rules: [Rule] }
    private let defaults: UserDefaults
    private let key = "writeflow.autoMountPolicies.v1"
    private var rules: [AutoMountFingerprint: AutoMountMode] = [:]
    private(set) var loadFailed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            if let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 {
                // 有歧义的重复规则整份拒绝，避免依赖字典覆盖顺序选择RW。
                for rule in document.rules {
                    guard rules[rule.fingerprint] == nil else { rules = [:]; loadFailed = true; return }
                    rules[rule.fingerprint] = rule.mode
                }
            } else { loadFailed = true }
        }
    }
    var savedRules: [(fingerprint: AutoMountFingerprint, mode: AutoMountMode)] { rules.map { ($0.key, $0.value) } }

    func mode(for fingerprint: AutoMountFingerprint?) -> AutoMountMode {
        guard let fingerprint else { return .off }
        return rules[fingerprint] ?? .off
    }
    @discardableResult func setMode(_ mode: AutoMountMode, for fingerprint: AutoMountFingerprint) -> Bool {
        guard mode != .readWrite || fingerprint.permitsRememberedWrite else { return false }
        if mode == .off { rules.removeValue(forKey: fingerprint) } else { rules[fingerprint] = mode }
        let document = Document(version: 1, rules: rules.map { Rule(fingerprint: $0.key, mode: $0.value) })
        guard let data = try? JSONEncoder().encode(document) else { return false }
        defaults.set(data, forKey: key)
        loadFailed = false
        return true
    }
}
