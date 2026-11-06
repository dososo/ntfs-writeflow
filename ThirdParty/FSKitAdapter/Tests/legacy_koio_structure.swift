import Foundation
import FSKit

@main
struct LegacyKOIOStructure {
    static func check(_ value: Bool, _ reason: String) {
        guard value else { fputs("失败：\(reason)\n", stderr); exit(1) }
    }
    static func main() async throws {
        let image = CommandLine.arguments[1]
        let before = try Data(contentsOf: URL(fileURLWithPath: image))
        guard let protocolType = NSProtocolFromString("FSVolumeKernelOffloadedIOOperations") else {
            fatalError("缺少公开KOIO协议")
        }
        var expectedID: UUID?
        for (major, minor, legacy) in [(26, 0, false), (15, 4, true), (15, 3, false),
                                       (15, 6, true), (25, 9, true), (26, 4, false), (27, 0, false)] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
            var error: Int32 = 0
            guard let b = nfsk_backend_from_file(image, 0, &error) else { throw posixError(error) }
            let volume = try ntfs3gFileSystem.volumeType(on: version).init(
                backend: NTFSBackend(backend: b, retain: nil, cleanup: {}, writable: false),
                mountBackend: { _, _, _ in nil }, onContainerStatusChange: { _ in })
            let erased: FSVolume = volume
            check((erased is any FSVolumeKernelOffloadedIOOperations) == legacy,
                "\(major).\(minor)卷实例KOIO协议隔离")
            check(erased.conforms(to: protocolType) == legacy, "Objective-C协议隔离与Swift一致")
            if !legacy { check(type(of: volume) == ntfs3gVolume.self, "现代与范围外只构造原基类") }
            let root = try volume.activate(taskOptions: [])
            let wanted = FSItem.GetAttributesRequest(); wanted.wantedAttributes = []
            let attrs = try await volume.attributes(wanted, of: root)
            check(attrs.inhibitKernelOffloadedIO == legacy, "仅旧子类统一设置普通IO回退值")
            check(attrs.isValid(.mode) && attrs.fileID.rawValue == NFSK_ROOT_INO && attrs.uid == 0,
                "继承原根属性，不因子类改变普通元数据")
            if let expectedID { check(volume.volumeID.uuid == expectedID, "子类不改变卷身份") }
            else { expectedID = volume.volumeID.uuid }
            if let koio = erased as? any FSVolumeKernelOffloadedIOOperations {
                do {
                    try await koio.completeIO(for: root, offset: 0, length: 0,
                        status: posixError(EIO), flags: [], operationID: .unspecified)
                    check(false, "意外completeIO不得伪报成功")
                } catch { check((error as NSError).code == Int(ENOTSUP), "意外completeIO明确ENOTSUP") }
            }
            volume.teardown()
        }
        check((try? Data(contentsOf: URL(fileURLWithPath: image))) == before, "结构检查保持镜像字节不变")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), format: nil) as! [String: Any]
        let attributes = info["EXAppExtensionAttributes"] as! [String: Any]
        check(attributes["FSSupportsKernelOffloadedIO"] as? Bool == true, "公开模块能力声明与旧子类一致")
        print("结构隔离通过：7个版本边界、Swift/ObjC协议一致、旧回退值/现代基类、根属性/身份不变、意外completeIO拒绝、镜像零变化")
        print("此处仅结构与普通文件引擎；inhibit有效位另测，不能当真实路由或VFS通过")
    }
}
