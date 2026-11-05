import Foundation

@main enum ExtensionDiagnosticTests {
    static func main() throws {
        var checks: [String] = [], failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            checks.append(name)
            if !condition { failures.append(name) }
        }
        for (major, minor, allowed) in [(13, 7, false), (15, 3, false), (15, 4, true), (15, 7, true), (25, 0, true), (26, 0, false), (27, 0, false)] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
            let missing = ExtensionDiagnostic.fsKitResult(moduleEnabled: nil, version: version)
            check("\(major).\(minor)枚举缺失的手动边界", missing.canAttemptManualMount == allowed)
            check("\(major).\(minor)枚举缺失不得冒称启用", !missing.isEnabled)
            if allowed {
                check("\(major).\(minor)说明系统核验与自动暂停", missing.detail.contains("手动") && missing.detail.contains("系统") && missing.detail.contains("暂停"))
            }
            for enabled in [true, false] {
                let listed = ExtensionDiagnostic.fsKitResult(moduleEnabled: enabled, version: version)
                check("\(major).\(minor)明确启用状态\(enabled)", listed.isEnabled == enabled && listed.canAttemptManualMount == enabled)
            }
        }
        check("等待查询不能手动尝试", !ExtensionDiagnostic.pending.canAttemptManualMount)
        for title in ["扩展状态查询失败", "兼容运行时尚未就绪", "当前虚拟机不支持兼容挂载"] {
            let diagnostic = ExtensionDiagnostic(title: title, detail: "测试拒绝", isEnabled: false)
            check("\(title)默认关闭手动入口", !diagnostic.canAttemptManualMount)
        }
        let legacyReady = ExtensionDiagnostic(title: "兼容运行时已就绪", detail: "测试旧流程", isEnabled: true)
        check("旧后端已就绪保留原手动行为", legacyReady.canAttemptManualMount)
        let result: [String: Any] = ["结果": failures.isEmpty ? "通过" : "失败", "数量": checks.count,
            "检查": checks, "失败": failures,
            "边界": "生产诊断纯转换与状态策略；没有调用FSClient、安装、授权、连接助手或操作设备。"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        exit(failures.isEmpty ? 0 : 1)
    }
}
