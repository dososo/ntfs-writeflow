import Foundation
import ObjectiveC

@main
struct PolicyChecks {
    static func main() throws {
        let cases: [([String], Bool)] = [
            ([], true), (["-o", "rw"], false), (["-orw"], false),
            (["-o", "ro,rw"], true), (["rw", "ro"], true),
            (["-o", "rdonly"], true), (["-o", "owners"], true)
        ]
        for (options, expected) in cases {
            precondition(ntfs3gFileSystem.defaultsToReadOnly(options) == expected, "只读策略不符：\(options)")
        }
        let noIdentity = try ntfs3gFileSystem.expectedMediaID([])
        let identity = try ntfs3gFileSystem.expectedMediaID(["-o", "rw,writeflow-media-id=123"])
        let repeatedIdentity = try ntfs3gFileSystem.expectedMediaID(["-owriteflow-media-id=123", "writeflow-media-id=123"])
        precondition(noIdentity == nil && identity == 123 && repeatedIdentity == 123)
        for invalid in ["", "0", "-1", "abc", "18446744073709551616", "1,writeflow-media-id=2"] {
            do {
                _ = try ntfs3gFileSystem.expectedMediaID(["-o", "writeflow-media-id=" + invalid])
                preconditionFailure("不应接受无效或冲突的介质标识")
            } catch { precondition((error as NSError).code == Int(EINVAL)) }
        }
        precondition(class_getInstanceMethod(ntfs3gVolume.self, NSSelectorFromString("enableOpenUnlinkEmulation")) != nil,
                     "缺少 FSKit 打开后删除仿真属性读取方法")
        precondition(class_getInstanceMethod(ntfs3gVolume.self, NSSelectorFromString("setEnableOpenUnlinkEmulation:")) != nil,
                     "缺少 FSKit 协议要求的属性设置方法")
        let valid = try ntfs3gFileSystem.CheckMode(options: ["-q"])
        precondition(valid == .quick)
        do {
            _ = try ntfs3gFileSystem.CheckMode(options: ["-qy"])
            preconditionFailure("不应接受同时检查与修复的混合参数")
        } catch { precondition((error as NSError).code == Int(EINVAL)) }
        print("适配层策略测试通过：7 组挂载策略、2 个协议选择器、2 组检查参数。")
    }
}
