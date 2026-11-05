import CoreFoundation
import Foundation

// 仅控制限时诊断日志，不参与挂载授权；不存在、无效或到期均不记录。
struct SessionVerificationRequest: Equatable {
    static let defaultsKey = "writeflow.sessionVerification"
    let id: String
    let createdAt: TimeInterval
    let expiresAt: TimeInterval

    static func parse(_ raw: Any?, now: Date = Date()) -> Self? {
        guard let dictionary = raw as? [String:Any], Set(dictionary.keys) == ["版本","编号","创建时间","到期时间"],
              number(dictionary["版本"]) == 1, let id = dictionary["编号"] as? String,
              UUID(uuidString:id)?.uuidString == id,
              let created = number(dictionary["创建时间"]), let expires = number(dictionary["到期时间"]),
              created >= 0, created <= now.timeIntervalSince1970, expires > now.timeIntervalSince1970,
              expires > created, expires - created <= 21600 else { return nil }
        return Self(id:id,createdAt:created,expiresAt:expires)
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
