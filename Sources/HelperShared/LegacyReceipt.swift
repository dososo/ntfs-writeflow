import Foundation
import Darwin
import CoreFoundation

struct LegacyReceipt: Equatable, Sendable {
    let userID: UInt32
    let wholeMediaRegistryID: UInt64
    let token: String
    let status: Int

    // 调用方先取得同一持久锁文件的独占租约；pread不改变子进程共享FD偏移。
    // nil仅表示首次启动的空文件，卸载与弹出不得把nil当作成功回执。
    static func read(from descriptor: Int32) throws -> LegacyReceipt? {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 4096 else {
            throw HelperFailure(message: "兼容后端回执不可读、类型错误或超过4096字节。")
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HelperFailure(message: "兼容后端回执尚未完整写入。") }
            offset += count
        }
        var header: UInt8 = 0, count: Int
        repeat { count = pread(descriptor, &header, 1, 0) } while count < 0 && errno == EINTR
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw HelperFailure(message: "兼容后端回执在读取期间发生变化。")
        }
        if bytes.isEmpty {
            guard count == 0 else { throw HelperFailure(message: "空回执在读取期间发生变化。") }
            return nil
        }
        guard count == 1, header == 1, bytes.first == 1, bytes.count > 1 else {
            throw HelperFailure(message: "兼容后端仍在运行、最终状态未知或回执未提交。")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(bytes.dropFirst())) }
        catch { throw HelperFailure(message: "兼容后端最终回执JSON不完整或无效。") }
        guard let values = object as? [String: Any],
              Set(values.keys) == ["version", "userID", "wholeMediaRegistryID", "token", "status"],
              integer(values["version"]) == 1,
              let user = integer(values["userID"]), user >= 501, user < UInt64(UInt32.max),
              let whole = integer(values["wholeMediaRegistryID"]), whole > 0,
              let token = values["token"] as? String, UUID(uuidString: token)?.uuidString == token,
              let status = integer(values["status"]), status <= 255 else {
            throw HelperFailure(message: "兼容后端回执版本、字段类型、范围或身份格式无效。")
        }
        return LegacyReceipt(userID: UInt32(user), wholeMediaRegistryID: whole, token: token, status: Int(status))
    }

    func requireClean(wholeMediaRegistryID: UInt64, userID: UInt32? = nil, token: String? = nil) throws {
        guard status == 0, self.wholeMediaRegistryID == wholeMediaRegistryID,
              userID == nil || self.userID == userID, token == nil || self.token == token else {
            throw HelperFailure(message: "兼容后端没有对应整盘、用户和凭据的成功关闭回执（状态\(status)），请保留介质。")
        }
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)) else { return nil }
        let text = number.stringValue
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }
}
