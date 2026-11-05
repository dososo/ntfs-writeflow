import Foundation
import FSKit

struct ExtensionDiagnostic {
    var title: String
    var detail: String
    var isEnabled: Bool

    static let pending = ExtensionDiagnostic(title: "正在查询", detail: "正在读取系统扩展状态。", isEnabled: false)

    @MainActor static func load() async -> ExtensionDiagnostic {
        if let reason = LegacyMountEnvironment.currentUnavailableReason() {
            return ExtensionDiagnostic(title: "当前虚拟机不支持兼容挂载", detail: reason, isEnabled: false)
        }
        if #unavailable(macOS 15.4) {
            do {
                try LegacyRuntime.checkInstalled()
                return ExtensionDiagnostic(title: "兼容运行时已就绪",
                    detail: "将使用用户安装的macFUSE兼容后端；内核授权、实际挂载与读写结果仍逐次核验。", isEnabled: true)
            } catch {
                return ExtensionDiagnostic(title: "兼容运行时尚未就绪",
                    detail: "macOS 13～15.3需要用户自行安装并批准macFUSE。\(error.localizedDescription)", isEnabled: false)
            }
        }
        guard #available(macOS 15.4, *) else { return .pending }
        do {
            let modules = try await FSClient.shared.installedExtensions
            guard let module = modules.first(where: { $0.bundleIdentifier == "com.blteam.ntfsworkbench.filesystem" }) else {
                return ExtensionDiagnostic(title: "尚未发现本应用扩展", detail: "系统尚未列出本应用的 NTFS 扩展。", isEnabled: false)
            }
            return ExtensionDiagnostic(title: module.isEnabled ? "扩展已启用" : "扩展未启用",
                detail: module.isEnabled ? "系统已列出并启用扩展；签名授权、实际加载与读写仍需单独验证。" : "扩展已安装，但系统尚未将其启用。",
                isEnabled: module.isEnabled)
        } catch {
            let error = error as NSError
            return ExtensionDiagnostic(title: "扩展状态查询失败", detail: "系统错误：\(error.domain)（\(error.code)）。", isEnabled: false)
        }
    }
}
