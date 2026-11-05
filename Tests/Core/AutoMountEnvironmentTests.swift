import Foundation

@main enum AutoMountEnvironmentTests {
    static func check(_ ok: Bool, _ name: String) { precondition(ok, name) }
    static func mustFail(_ name: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(name) } catch { }
    }
    static func main() async throws {
        check(AutoMountEnvironment.parseLoaded("Index Refs Address Size Wired Name (Version)\n1 0 0xffff 100 100 io.vendor.Driver (1.0)\n") == ["io.vendor.Driver"], "io前缀不能漏过")
        check(AutoMountEnvironment.parseLoaded("Index Refs Address Size Wired Name (Version)\n1 0 0xffff 100 100 de.vendor.Driver (1.0)\n") == ["de.vendor.Driver"], "其他前缀不能漏过")
        check(AutoMountEnvironment.parseLoaded("Index Refs Address Size Wired Name (Version)\n1 0 0xffff 100 100 ????\n") == nil, "坏行不能丢弃后声称完整")
        check(AutoMountEnvironment.parseRegistered("+    com.apple.fskit.exfat(1.0)\n+    io.vendor.fs(0.1)\n") == ["com.apple.fskit.exfat","io.vendor.fs"], "全部注册模块都须解析")
        check(AutoMountEnvironment.parseRegistered("     com.apple.fskit.exfat((null))\n") == ["com.apple.fskit.exfat"],"系统空版本模块应完整解析")
        check(AutoMountEnvironment.parseRegistered("unexpected text\n") == nil,"未知注册清单不能冒充空表")
        check(!AutoMountEnvironment.classify(filesystems:[],extensions:[],loaded:["io.vendor.Driver"],modules:[]).isClear,"未知加载项停止自动挂载")
        let text = try AutoMountEnvironment.query("/bin/echo", ["公开状态"], timeout:1, maximumBytes:1024)
        check(text == "公开状态\n","完整读出状态")
        mustFail("退出失败须可见") { _ = try AutoMountEnvironment.query("/usr/bin/false", [],timeout:1,maximumBytes:1024) }
        mustFail("非UTF8须拒绝") { _ = try AutoMountEnvironment.query("/usr/bin/printf", ["\\377"],timeout:1,maximumBytes:1024) }
        mustFail("输出超过上限须有界拒绝") { _ = try AutoMountEnvironment.query("/usr/bin/yes", [],timeout:1,maximumBytes:512) }
        let clock = ContinuousClock(); let start = clock.now
        mustFail("忽略TERM或仍持有stdout时也必须有界返回") {
            _ = try AutoMountEnvironment.query("/bin/sh", ["-c", "trap '' TERM; sleep 1"],timeout:0.1,maximumBytes:1024)
        }
        check(start.duration(to:clock.now) < .seconds(0.7),"超时不得等到子进程结束")
        if CommandLine.arguments.contains("--live") {
            let environment = await AutoMountEnvironment.load()
            print("本机只读环境：\(environment.isClear ? "未发现竞争" : "已暂停")；\(environment.reason)")
        }
        print("通过：13项完整解析、未知拒绝、输出限额和真实自有子进程超时检查；未操作磁盘或其他进程。")
    }
}
