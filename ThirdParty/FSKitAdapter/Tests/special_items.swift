import Foundation
import FSKit

@available(macOS 15.4, *)
@main struct SpecialItems {
    static func backend(_ image: String, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: writable)
    }

    static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("特殊项必须拒绝") }
        catch { precondition((error as NSError).code == Int(ENOTSUP), "错误码不符：\(error)") }
    }

    static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        let image = CommandLine.arguments[1]
        let ids = try JSONDecoder().decode([UInt64].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        precondition(ids.count == 4)
        let names = ["字符项", "块项", "管道项", "套接字项"]
        for legacy in [false, true] {
            let volume = try ntfs3gVolume(backend: backend(image, writable: false),
                mountBackend: { _, _, _ in try backend(image, writable: true) },
                onContainerStatusChange: { _ in }, legacyOpenUnlink: legacy)
            let root = try volume.activate(taskOptions: ["-o", "rw"])
            try volume.mountVolume()
            for (index, ino) in ids.enumerated() {
                let item = ntfs3gItem(ino: ino, parentIno: NFSK_ROOT_INO, name: FSFileName(string: names[index]))
                try await rejected { try await volume.openItem(item, modes: [.read]) }
                try await rejected { _ = try await volume.attributes(FSItem.GetAttributesRequest(), of: item) }
                try await rejected { _ = try await volume.lookupItem(named: FSFileName(string: names[index]), inDirectory: root) }
            }
            for type: FSItem.ItemType in [.fifo, .charDevice, .blockDevice, .socket] {
                try await rejected {
                    _ = try await volume.createItem(named: FSFileName(string: "不可创建特殊项"), type: type,
                        inDirectory: root, attributes: FSItem.SetAttributesRequest())
                }
            }
            for type: FSItem.ItemType in [.file, .directory] {
                let name = FSFileName(string: "权限对照-\(legacy)-\(type.rawValue)")
                let requested = FSItem.SetAttributesRequest()
                requested.mode = 0o6777; requested.uid = 501; requested.gid = 20
                let (item, _) = try await volume.createItem(named: name, type: type, inDirectory: root, attributes: requested)
                let before = try await volume.attributes(FSItem.GetAttributesRequest(), of: item)
                precondition(before.type == type && before.mode & 0o6000 == 0)
                precondition(!requested.consumedAttributes.contains(.mode) &&
                    !requested.consumedAttributes.contains(.uid) && !requested.consumedAttributes.contains(.gid))
                let changed = FSItem.SetAttributesRequest()
                changed.mode = 0o6755; changed.uid = 0; changed.gid = 0
                let after = try await volume.setAttributes(changed, on: item)
                precondition(after.mode == before.mode && after.uid == before.uid && after.gid == before.gid)
                precondition(after.mode & 0o6000 == 0 && changed.consumedAttributes.isEmpty)
                try await volume.openItem(item, modes: [.read])
                try await volume.closeItem(item, modes: [])
            }
            let linkName = FSFileName(string: "链接权限对照-\(legacy)")
            let metadata = FSItem.SetAttributesRequest(); metadata.mode = 0o6777
            let (link, _) = try await volume.createSymbolicLink(named: linkName, inDirectory: root,
                attributes: metadata, linkContents: FSFileName(string: "普通文件"))
            let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: link)
            precondition(attributes.type == .symlink && attributes.mode & 0o6000 == 0)
            let target = try await volume.readSymbolicLink(link)
            precondition(target.string == "普通文件" && !metadata.consumedAttributes.contains(.mode))
            try await volume.synchronize(flags: .wait)
            volume.teardown()
        }
        print("FSVolume通过：新旧open策略均拒绝四类预制特殊项/新建特殊项；普通文件目录链接不变，mode/uid/gid未消费，setuid/setgid始终为零。")
        print("边界：只在自建普通镜像直接调用生产FSVolume；不代表内核flags或真实设备挂载验收。")
    }
}
