import Foundation
import FSKit

@main
struct KOIOFallbackChecks {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 2)
        var error: Int32 = 0
        guard let b = nfsk_backend_from_file(CommandLine.arguments[1], 0, &error) else { throw posixError(error) }
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        let volume = try ntfs3gFileSystem.volumeType(on: version).init(backend: NTFSBackend(backend: b, retain: nil, cleanup: {}, writable: false),
            mountBackend: { _, _, _ in nil }, onContainerStatusChange: { _ in })
        defer { volume.teardown() }
        let root = try volume.activate(taskOptions: [])
        let wanted = FSItem.GetAttributesRequest(); wanted.wantedAttributes = []
        let attrs = try await volume.attributes(wanted, of: root)
        print("公开属性回归：值=\(attrs.inhibitKernelOffloadedIO) 有效=\(attrs.isValid(.inhibitKernelOffloadedIO)) mode有效=\(attrs.isValid(.mode))"); fflush(stdout)
        precondition(attrs.inhibitKernelOffloadedIO && attrs.isValid(.inhibitKernelOffloadedIO),
                     "所有item必须无条件有效地标记普通IO回退，即使系统没有请求该属性")
        let erased: FSVolume = volume
        precondition(erased is any FSVolumeKernelOffloadedIOOperations, "必须真实遵循双IO协议")
        print("KOIO普通IO回退属性通过")
    }
}
