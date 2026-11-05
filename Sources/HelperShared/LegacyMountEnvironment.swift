import Foundation
import Darwin

enum LegacyMountEnvironment {
    static func unavailableReason(backend: StorageBackend, virtualMachine: Int32?, model: String?) -> String? {
        guard backend == .macFUSE, virtualMachine == 1, let model,
              let range = model.range(of: #"^VirtualMac[0-9]+,[0-9]+$"#, options: .regularExpression),
              range.lowerBound == model.startIndex, range.upperBound == model.endIndex else { return nil }
        return "当前Apple虚拟机不支持macFUSE内核扩展，macOS 13～15.3的兼容挂载在此环境不可用。请在兼容的实体Mac上验证，或在macOS 15.4及以上使用本应用FSKit路径。"
    }

    static func currentUnavailableReason() -> String? {
        let backend = StorageBackend.current
        guard backend == .macFUSE else { return nil }
        var marker: Int32 = 0, markerSize = MemoryLayout<Int32>.size
        let knownMarker = sysctlbyname("kern.hv_vmm_present", &marker, &markerSize, nil, 0) == 0
            && markerSize == MemoryLayout<Int32>.size
        var modelSize = 0
        var model: String?
        if sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0, modelSize > 0, modelSize <= 256 {
            var value = [CChar](repeating: 0, count: modelSize)
            if sysctlbyname("hw.model", &value, &modelSize, nil, 0) == 0 {
                model = String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return unavailableReason(backend: backend, virtualMachine: knownMarker ? marker : nil, model: model)
    }
}
