import Foundation
import Darwin

@main enum LegacyMountEnvironmentTests {
    static func main() throws {
        var checks: [String] = [], failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            checks.append(name)
            if !value { failures.append(name) }
        }
        for model in ["VirtualMac1,1", "VirtualMac2,1", "VirtualMac12,0"] {
            let reason = LegacyMountEnvironment.unavailableReason(backend: .macFUSE, virtualMachine: 1, model: model)
            check("旧后端的明确Apple虚拟机拒绝：\(model)", reason != nil)
            check("拒绝原因说明平台内核限制：\(model)", reason?.contains("虚拟机") == true && reason?.contains("内核") == true)
            check("FSKit不受同一虚拟机标记影响：\(model)", LegacyMountEnvironment.unavailableReason(backend: .fsKit, virtualMachine: 1, model: model) == nil)
        }
        for model: String? in [nil, "", "Mac16,8", "VMware7,1", "Parallels ARM Virtual Machine", "VirtualMac", "VirtualMac2,1其他", "VirtualMac2,1\n", " VirtualMac2,1", "VirtualMac2,", "VirtualMacx,1"] {
            check("未知、实体或其他虚拟机不冒称受限：\(model ?? "缺失")", LegacyMountEnvironment.unavailableReason(backend: .macFUSE, virtualMachine: 1, model: model) == nil)
        }
        for marker: Int32? in [nil, 0, -1, 2] {
            check("缺失或非1标记不冒称已确认虚拟机：\(marker.map(String.init) ?? "缺失")", LegacyMountEnvironment.unavailableReason(backend: .macFUSE, virtualMachine: marker, model: "VirtualMac2,1") == nil)
        }
        check("FSKit当前路径不会因宿主虚拟化能力被禁用", StorageBackend.current != .fsKit || LegacyMountEnvironment.currentUnavailableReason() == nil)
        let result: [String: Any] = ["结果": failures.isEmpty ? "通过" : "失败", "数量": checks.count,
            "检查": checks, "失败": failures,
            "边界": "分类输入正反例与当前系统只读探测；没有安装、加载内核、创建票据、挂载或真实旧guest执行。"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        exit(failures.isEmpty ? 0 : 1)
    }
}
