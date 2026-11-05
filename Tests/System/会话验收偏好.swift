import CoreFoundation
import Foundation

// 固定域、固定单键；不提供任意defaults写入或服务登记入口。
private let domain = "com.blteam.ntfsworkbench" as CFString
private let key = "writeflow.sessionVerification" as CFString

@MainActor private func value(_ key: CFString) -> AnyObject? {
    CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}
@MainActor private func effectiveValue(_ key: CFString) -> AnyObject? { CFPreferencesCopyAppValue(key, domain) }
@MainActor private func snapshot() throws -> [String: Any] {
    guard let current = value(key) else { return ["存在": false, "值Base64": NSNull()] }
    let data = try PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0)
    return ["存在": true, "值Base64": data.base64EncodedString()]
}
private func decode(_ raw: [String: Any]) throws -> AnyObject? {
    guard Set(raw.keys) == ["存在", "值Base64"], let present = raw["存在"] as? NSNumber,
          CFGetTypeID(present) == CFBooleanGetTypeID() else { throw failure("偏好快照格式不符") }
    if !present.boolValue {
        guard raw["值Base64"] is NSNull else { throw failure("不存在快照仍含数据") }
        return nil
    }
    guard let encoded = raw["值Base64"] as? String, let data = Data(base64Encoded: encoded), data.count <= 32768 else {
        throw failure("偏好快照不是有界plist")
    }
    return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as AnyObject
}
private func equal(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    guard CFGetTypeID(a) == CFGetTypeID(b) else { return false }
    if let left = a as? NSDictionary, let right = b as? NSDictionary {
        guard left.count == right.count else { return false }
        return left.allKeys.allSatisfy { k in equal(left.object(forKey: k) as AnyObject?, right.object(forKey: k) as AnyObject?) }
    }
    if let left = a as? NSArray, let right = b as? NSArray {
        return left.count == right.count && (0..<left.count).allSatisfy { equal(left[$0] as AnyObject, right[$0] as AnyObject) }
    }
    if let left = a as? NSNumber, let right = b as? NSNumber,
       String(cString: left.objCType) != String(cString: right.objCType) { return false }
    return CFEqual(a,b)
}
private func autoState(_ raw: AnyObject?) -> String {
    guard let raw else { return "关闭" }
    guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return "未知" }
    return n.boolValue ? "开启" : "关闭"
}
private func report(precise: AnyObject?, effective: AnyObject?, auto: AnyObject?, currentHostPresent: Bool = false, forced: Bool = false) -> [String: Any] {
    ["专用键遮蔽": currentHostPresent || forced || !equal(precise,effective), "自动管理": autoState(auto),
     "当前主机键存在": currentHostPresent, "受管键": forced]
}
@MainActor private func preferenceReport() -> [String: Any] {
    report(precise: value(key), effective: effectiveValue(key), auto: effectiveValue("writeflow.autoMount.enabled" as CFString),
           currentHostPresent: CFPreferencesCopyValue(key,domain,kCFPreferencesCurrentUser,kCFPreferencesCurrentHost) != nil,
           forced: CFPreferencesAppValueIsForced(key,domain))
}
private func failure(_ text: String) -> NSError { NSError(domain: "会话验收偏好", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
private func validRequest(_ raw: AnyObject?) -> Bool {
    guard let dictionary = raw as? [String: Any], Set(dictionary.keys) == ["版本","编号","创建时间","到期时间"],
          let id = dictionary["编号"] as? String, UUID(uuidString: id)?.uuidString == id else { return false }
    func number(_ name: String) -> Double? {
        guard let n = dictionary[name] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    guard number("版本") == 1, let created = number("创建时间"), let expiry = number("到期时间") else { return false }
    let now = Date().timeIntervalSince1970
    return created >= 0 && created <= now && now < expiry && expiry - created <= 21600
}

do {
    guard CommandLine.arguments.count == 2, ["read","arm","restore","compare","inspect"].contains(CommandLine.arguments[1]) else { throw failure("只接受固定操作") }
    let operation = CommandLine.arguments[1]
    if operation == "compare" {
        let data = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let before = input["旧值"] as? [String: Any], let after = input["新值"] as? [String: Any] else { throw failure("纯比较输入不符") }
        let output = try JSONSerialization.data(withJSONObject: ["相等": equal(try decode(before), try decode(after))])
        FileHandle.standardOutput.write(output + Data([10])); exit(0)
    }
    if operation == "inspect" {
        let data = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let precise = input["精确键"] as? [String: Any], let effective = input["有效键"] as? [String: Any],
              let auto = input["有效自动管理"] as? [String: Any] else { throw failure("纯诊断输入不符") }
        let host = input["当前主机键存在"] as? Bool ?? false, forced = input["受管键"] as? Bool ?? false
        let output = try JSONSerialization.data(withJSONObject: report(precise: try decode(precise), effective: try decode(effective), auto: try decode(auto), currentHostPresent: host, forced: forced))
        FileHandle.standardOutput.write(output + Data([10])); exit(0)
    }
    guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw failure("无法同步当前用户偏好") }
    if operation != "read" {
        let data = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(input.keys) == ["旧值","新值"], let before = input["旧值"] as? [String: Any], let after = input["新值"] as? [String: Any] else {
            throw failure("只接受有界比较后写入请求")
        }
        let expected = try decode(before), replacement = try decode(after)
        guard preferenceReport()["专用键遮蔽"] as? Bool == false else { throw failure("验收配置存在主机/受管或其他来源遮蔽，拒绝写入任何域") }
        guard equal(value(key), expected) else { throw failure("专用验收键已变化，拒绝覆盖") }
        if operation == "arm" {
            guard validRequest(replacement) else { throw failure("arm配置不符合期限或类型规则") }
            guard autoState(effectiveValue("writeflow.autoMount.enabled" as CFString)) == "关闭" else { throw failure("arm写入前有效自动管理不再明确关闭") }
        }
        CFPreferencesSetValue(key, replacement, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), equal(value(key), replacement), equal(effectiveValue(key),replacement) else {
            throw failure("专用键写入未确认；保留原始备份，勿覆盖其他偏好")
        }
    }
    var result = preferenceReport()
    result["专用键"] = try snapshot(); result["域"] = domain; result["唯一键"] = key
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(output + Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
