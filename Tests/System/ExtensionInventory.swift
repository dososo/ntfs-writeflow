import Foundation
import FSKit
import Darwin

// 仅查询系统公开 API；不注册、启用、挂载或修改磁盘。
@main enum ExtensionInventory {
    static func main() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            let targets = modules.filter { $0.bundleIdentifier == "com.blteam.ntfsworkbench.filesystem" }
            let result: [String: Any] = [
                "检查": "FSKit 系统扩展清单",
                "调用方可见扩展数": modules.count,
                "本应用扩展数": targets.count,
                "扩展": targets.map { ["标识": $0.bundleIdentifier, "路径": $0.url.path, "启用": $0.isEnabled] as [String: Any] }
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if targets.count != 1 || targets.first?.isEnabled != true { exit(3) }
        } catch {
            fputs("FSKit 查询失败：\(error)\n", stderr)
            exit(1)
        }
    }
}
