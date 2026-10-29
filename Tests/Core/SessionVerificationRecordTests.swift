import AppKit
import Foundation
import Darwin

@main enum SessionVerificationRecordTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName:"writeflow.verification.test.\(UUID().uuidString)")!
        let model = AppModel(defaults:defaults,autoMountRuntime:AutoMountRuntime(record:{_ in nil},mount:{_,_ in},
            environment:{AutoMountEnvironment(isClear:false,reason:"测试")},sessionAllowed:{false},loginState:{.notRegistered}))
        func check(_ value:Bool,_ why:String) { if !value { print("失败：\(why)");exit(1) } }
        check(model.sessionVerificationRecord("启动完成")==nil && model.verificationSequence==0,"默认状态不应记录或消耗序号")
        let id=UUID().uuidString
        defaults.set(["版本":1,"编号":id,"创建时间":Date().timeIntervalSince1970-1,"到期时间":Date().timeIntervalSince1970+60],forKey:SessionVerificationRequest.defaultsKey)
        model.autoSession.confirmForeground(applicationActive:true,consoleUserCurrent:true,protectedDataAvailable:true)
        model.autoForegroundRequest=(model.autoSessionRevocationEpoch,ProcessInfo.processInfo.systemUptime+5)
        let epoch=model.autoSessionRevocationEpoch
        guard let first=model.sessionVerificationRecord("即将完成启动"),let second=model.sessionVerificationRecord("启动窗口采样",seconds:1) else { exit(1) }
        check(first["原始事件ID"] is NSNull && first["原始启动原因"] is NSNull && first["登录启动"] is NSNull,"启动早期缺值应保留为null")
        check(model.autoSession.foregroundConfirmed && model.autoForegroundRequest != nil && model.autoSessionRevocationEpoch==epoch,"只读记录修改了会话授权")
        check(first["验收编号"] as? String==id && first["进程会话"] as? String==second["进程会话"] as? String,"关联身份不稳定")
        check(first["序号"] as? Int==1 && second["序号"] as? Int==2,"序号未严格递增")
        check(first["信号"] is NSNull && second["采样秒数"] as? Int==1,"固定nullable字段缺失")
        check(first["PID"] as? Int32==getpid() && first["UID"] as? UInt32==getuid() && first["EUID"] as? UInt32==geteuid(),"进程身份字段不匹配")
        check((first["主程序SHA256"] as? String)?.count==64,"未绑定主程序摘要")
        let expected:Set<String>=["格式","验收编号","进程会话","序号","事件","时间","PID","UID","EUID","应用标识","版本","构建","主程序SHA256","原始事件ID","原始启动原因","登录启动","登录项状态","登录项已启用","自动管理","前台确认","待确认","撤销代数","工作区活动","数据保护","数据保护闭锁","睡眠闭锁","控制台UID","调用进程会话UID","调用会话在控制台","控制台当前用户","应用活动","激活策略","可见内容窗数","最小化内容窗数","内容窗角色","磁盘监控存在","会话监控存在","采样秒数","信号"]
        check(first["格式"] as? Int == 2 && Set(first.keys)==expected,"日志字段越出必要白名单")
        let text=String(data:try! JSONSerialization.data(withJSONObject:first),encoding:.utf8)!
        check(!text.contains(NSHomeDirectory()) && !text.contains("/dev/") && !text.contains("/Volumes/"),"日志泄露路径")
        model.verificationSequence=256
        check(model.sessionVerificationRecord("正常退出")==nil,"超过上限仍记录")
        defaults.set(["版本":1,"编号":UUID().uuidString,"创建时间":Date().timeIntervalSince1970-1,"到期时间":Date().timeIntervalSince1970+60],forKey:SessionVerificationRequest.defaultsKey)
        check(model.sessionVerificationRecord("重新打开")?["序号"] as? Int==1,"新验收编号未从1记录")
        defaults.set(["版本":1,"编号":id,"创建时间":1.0,"到期时间":2.0],forKey:SessionVerificationRequest.defaultsKey)
        check(model.sessionVerificationRecord("正常退出")==nil,"过期仍记录")
        check(!model.autoEnabled && model.diskMonitor==nil,"记录日志改变了自动管理或启动磁盘监控")
        model.stopMonitoring()
        print("正式模型验收日志记录14项通过：默认关闭、限时、关联序号、身份摘要、字段最小化、记录上限；未向系统日志写入测试记录或操作磁盘。")
    }
}
