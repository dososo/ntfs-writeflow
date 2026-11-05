import Foundation
import ObjectiveC

@main
struct PolicyChecks {
    static func main() throws {
        let cases: [([String], Bool)] = [
            ([], true), (["-o", "rw"], false), (["-orw"], false),
            (["-o", "ro,rw"], true), (["rw", "ro"], true),
            (["-o", "rdonly"], true), (["-o", "owners"], true),
            (["rw,nosuid,nodev,writeflow-media-id=9"], false),
            (["rw,ro,writeflow-media-id=9"], true), (["ro", "rw,nosuid"], true),
            (["norw"], true), (["rw=no"], true)
        ]
        for (options, expected) in cases {
            precondition(ntfs3gFileSystem.defaultsToReadOnly(options) == expected, "只读策略不符：\(options)")
        }
        let writableOptions = ["rw,nosuid,writeflow-media-id=9"]
        let resolvedWrite = try ntfs3gFileSystem.resolvedMountReadOnly(writableOptions, resourceWritable: true)
        precondition(!resolvedWrite)
        for (options, writable, code): ([String], Bool, Int32) in [
            (writableOptions, false, EROFS), (["rw"], true, ESTALE),
            (["rw,writeflow-media-id=9", "-o", "writeflow-media-id=10"], true, EINVAL)] {
            do {
                _ = try ntfs3gFileSystem.resolvedMountReadOnly(options, resourceWritable: writable)
                preconditionFailure("写入缺少资源权限或原介质身份时不能放行")
            } catch { precondition((error as NSError).code == Int(code)) }
        }
        let implicitRead = try ntfs3gFileSystem.resolvedMountReadOnly([], resourceWritable: false)
        let dominantRead = try ntfs3gFileSystem.resolvedMountReadOnly(["ro,rw"], resourceWritable: false)
        precondition(implicitRead && dominantRead)
        let pathWrite = try ntfs3gFileSystem.resolvedMountReadOnly(["rw"], resourceWritable: true, blockResource: false)
        precondition(!pathWrite, "非block资源仍使用安全作用域URL和原FD，不要求虚构的IOMedia标识")
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
        precondition(class_getInstanceMethod(ntfs3gVolume.self, NSSelectorFromString("mountWithOptions:replyHandler:")) != nil,
                     "缺少15.4公开挂载回调选择器")
        let valid = try ntfs3gFileSystem.CheckMode(options: ["-q"])
        precondition(valid == .quick)
        do {
            _ = try ntfs3gFileSystem.CheckMode(options: ["-qy"])
            preconditionFailure("不应接受同时检查与修复的混合参数")
        } catch { precondition((error as NSError).code == Int(EINVAL)) }
        print("适配层策略测试通过：\(cases.count)组挂载策略、7组资源与介质许可、3个协议选择器、2组检查参数；无设备操作。")
    }
}
