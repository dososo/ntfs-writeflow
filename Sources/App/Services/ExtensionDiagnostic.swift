import Foundation
import FSKit

struct ExtensionDiagnostic {
    var title: String
    var detail: String
    var isEnabled: Bool
    private(set) var allowsManualMountWhenUnlisted = false
    var canAttemptManualMount: Bool { isEnabled || allowsManualMountWhenUnlisted }

    static let pending = ExtensionDiagnostic(title: "正在查询", detail: "正在读取系统扩展状态。", isEnabled: false)

    static func fsKitResult(moduleEnabled: Bool?, version: OperatingSystemVersion) -> ExtensionDiagnostic {
        guard let moduleEnabled else {
            let canAttempt = version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4)
            return ExtensionDiagnostic(title: canAttempt ? "系统枚举未列出本应用扩展" : "尚未发现本应用扩展",
                detail: canAttempt ? "请先在系统设置 → 通用 → 登录项与扩展 → 按类别 → 文件系统扩展中启用 NTFSFileSystem，再手动尝试挂载。正常系统挂载会继续核验授权与模块可用性；自动管理保持暂停。" : "系统尚未列出本应用的 NTFS 扩展。",
                isEnabled: false, allowsManualMountWhenUnlisted: canAttempt)
        }
        return ExtensionDiagnostic(title: moduleEnabled ? "扩展已启用" : "扩展未启用",
            detail: moduleEnabled ? "系统已列出并启用扩展；签名授权、实际加载与读写仍需单独验证。" : "扩展已安装，但系统尚未将其启用。",
            isEnabled: moduleEnabled)
    }

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
            return fsKitResult(moduleEnabled: modules.first(where: { $0.bundleIdentifier == "com.blteam.ntfsworkbench.filesystem" })?.isEnabled,
                version: ProcessInfo.processInfo.operatingSystemVersion)
        } catch {
            let error = error as NSError
            return ExtensionDiagnostic(title: "扩展状态查询失败", detail: "系统错误：\(error.domain)（\(error.code)）。", isEnabled: false)
        }
    }
}
