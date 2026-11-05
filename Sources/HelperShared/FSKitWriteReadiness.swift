import Foundation

// 仅旧FSKit的原资源写入准备；被动查询不得触发准备或接受盘上同名属性。
enum FSKitWriteReadiness {
    static let optionPrefix = "writeflow-ready-token="
    static let preparePrefix = "com.blteam.ntfsworkbench.write-prepare."
    static let statusPrefix = "com.blteam.ntfsworkbench.write-ready."
    static let maximumReceiptSize = 1024

    struct Receipt: Codable, Sendable {
        let schema: Int
        let token: String
        let mediaID: UInt64
        let writable: Bool
    }

    static func requires(backend: PrivilegedMountBackend, readOnly: Bool,
                         on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        backend == .fsKit && !readOnly && StorageBackend.requiresWriteReadiness(on: version)
    }

    static func option(token: String) throws -> String { optionPrefix + (try canonicalToken(token)) }
    static func prepareName(token: String) throws -> String { preparePrefix + (try canonicalToken(token)) }
    static func statusName(token: String) throws -> String { statusPrefix + (try canonicalToken(token)) }

    static func token(fromOption value: String) throws -> String {
        guard value.hasPrefix(optionPrefix) else { throw invalid() }
        return try canonicalToken(String(value.dropFirst(optionPrefix.count)))
    }

    static func token(fromName value: String, preparing: Bool) throws -> String {
        let prefix = preparing ? preparePrefix : statusPrefix
        guard value.hasPrefix(prefix) else { throw invalid() }
        return try canonicalToken(String(value.dropFirst(prefix.count)))
    }

    static func receipt(token: String, mediaID: UInt64) throws -> Data {
        guard mediaID > 0 else { throw invalid() }
        let value = Receipt(schema: 1, token: try canonicalToken(token), mediaID: mediaID, writable: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    @discardableResult
    static func validate(_ data: Data, token: String, mediaID: UInt64) throws -> Receipt {
        guard !data.isEmpty, data.count <= maximumReceiptSize, mediaID > 0,
              let text = String(data: data, encoding: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "token", "mediaID", "writable"]) else { throw invalid() }
        // 固定平面协议：拒绝重复/转义键、浮点/布尔冒充整数及额外字段。
        let keys = try NSRegularExpression(pattern: #"\"([^\"\\]+)\"\s*:"#)
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard keys.count == 4,
              Set(keys.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }) == Set(object.keys),
              text.range(of: #"\"schema\"\s*:\s*1\s*[,}]"#, options: .regularExpression) != nil,
              text.range(of: #"\"mediaID\"\s*:\s*[1-9][0-9]*\s*[,}]"#, options: .regularExpression) != nil,
              text.range(of: #"\"writable\"\s*:\s*true\s*[,}]"#, options: .regularExpression) != nil else { throw invalid() }
        let value = try JSONDecoder().decode(Receipt.self, from: data)
        guard value.schema == 1, value.token == (try canonicalToken(token)),
              try canonicalToken(value.token) == token, value.mediaID == mediaID, value.writable else { throw invalid() }
        return value
    }

    private static func canonicalToken(_ token: String) throws -> String {
        guard UUID(uuidString: token)?.uuidString == token else { throw invalid() }
        return token
    }

    private static func invalid() -> HelperFailure {
        HelperFailure(message: "未确认原挂载实例的内部写入准备回执。")
    }
}
