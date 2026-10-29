import Foundation
import FSKit

@main
struct VolumeRoundtrip {
    static func backend(_ path: String, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(path, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: writable)
    }

    static func expect(_ code: Int32, _ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("操作应被拒绝，错误码 \(code)") }
        catch { precondition((error as NSError).code == Int(code), "实际错误不符：\(error)") }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw posixError(EINVAL) }
        let image = CommandLine.arguments[1]
        let expectedPath = CommandLine.arguments[2]
        let volume = try ntfs3gVolume(backend: backend(image, writable: false),
            mountBackend: { _, _, _ in try backend(image, writable: true) }, onContainerStatusChange: { _ in })
        let root = try volume.activate(taskOptions: ["-o", "rw"])
        try volume.mountVolume()
        let originalName = FSFileName(string: "中文读写.txt")
        let finalName = FSFileName(string: "完成记录.txt")
        let (item, _) = try await volume.createItem(named: originalName, type: .file, inDirectory: root,
            attributes: FSItem.SetAttributesRequest())
        var expected = Data((0..<8193).map { UInt8($0 % 251) })
        let first = try await volume.write(contents: expected, to: item, at: 0)
        precondition(first == expected.count)
        let patch = Data("中文随机覆盖".utf8)
        let overwritten = try await volume.write(contents: patch, to: item, at: 13)
        precondition(overwritten == patch.count)
        expected.replaceSubrange(13..<(13 + patch.count), with: patch)
        let tail = Data("追加结尾".utf8)
        let appended = try await volume.write(contents: tail, to: item, at: off_t(expected.count))
        precondition(appended == tail.count)
        expected.append(tail)
        let metadata = FSItem.SetAttributesRequest()
        metadata.size = 4097
        metadata.birthTime = timespec(tv_sec: 946684800, tv_nsec: 0)
        let attributes = try await volume.setAttributes(metadata, on: item)
        expected = expected.prefix(4097)
        precondition(attributes.size == 4097 && attributes.birthTime.tv_sec == 946684800)
        let renamed = try await volume.renameItem(item, inDirectory: root, named: originalName,
            to: finalName, inDirectory: root, overItem: nil)
        precondition(renamed.string == finalName.string)
        let key = FSFileName(string: "com.blteam.adapter-test")
        let value = Data("元数据往返".utf8)
        try await volume.setXattr(named: key, to: value, on: item, policy: .mustCreate)
        let xattr = try await volume.xattr(named: key, of: item)
        precondition(xattr == value)
        try await volume.synchronize(flags: .wait)
        volume.teardown()
        try expected.write(to: URL(fileURLWithPath: expectedPath), options: .withoutOverwriting)

        let before = try Data(contentsOf: URL(fileURLWithPath: image))
        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            mountBackend: { _, _, _ in nil }, onContainerStatusChange: { _ in })
        try readOnly.quickCheck()
        _ = try readOnly.activate(taskOptions: ["-o", "rdonly"])
        try readOnly.mountVolume()
        let (reopened, _) = try await readOnly.lookupItem(named: finalName, inDirectory: root)
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.size, .birthTime]
        let reopenedAttributes = try await readOnly.attributes(get, of: reopened)
        precondition(reopenedAttributes.size == UInt64(expected.count))
        let reopenedXattr = try await readOnly.xattr(named: key, of: reopened)
        precondition(reopenedXattr == value)
        try await expect(EROFS) { _ = try await readOnly.write(contents: Data([1]), to: reopened, at: 0) }
        try await expect(EROFS) {
            _ = try await readOnly.createItem(named: FSFileName(string: "不应创建"), type: .file,
                inDirectory: root, attributes: FSItem.SetAttributesRequest())
        }
        try await expect(EROFS) { _ = try await readOnly.setVolumeName(FSFileName(string: "不应改名")) }
        readOnly.teardown()
        let after = try Data(contentsOf: URL(fileURLWithPath: image))
        precondition(before == after, "只读操作改变了镜像字节")
        print("直接 FSVolume 测试通过：中文创建、8193 字节写入、随机覆盖、追加、截断、时间戳、重命名、扩展属性、同步、重打开、只读拒绝与镜像不变。")
        print("未测试系统激活与读取回调：FSTaskOptions/FSMutableFileDataBuffer 需由系统提供；内容由 ntfscat 独立桥接复读。")
    }
}
