import Foundation

@main enum SessionStateTests {
    static func main() {
        var state = AutoMountSessionState()
        func check(_ condition: Bool, _ reason: String) { if !condition { print("失败：\(reason)"); exit(1) } }
        check(!state.permits(consoleUserCurrent:true), "未知状态不能授权")
        state.observeProtectedData(available:true)
        check(!state.permits(consoleUserCurrent:true), "受保护数据可用不能推定屏幕解锁")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(state.permits(consoleUserCurrent:true), "已确认前台会话应允许后续核验")
        state.observeProtectedData(available:false)
        check(!state.permits(consoleUserCurrent:true), "数据保护关闭必须撤销确认")
        state.observeProtectedData(available:true)
        check(!state.permits(consoleUserCurrent:true), "重新可用不得恢复旧确认")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:false, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "非控制台用户不能确认")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:false)
        check(!state.permits(consoleUserCurrent:true), "前台也不能绕过负向数据保护")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:false), "控制台身份变化须拒绝")
        state.revoke()
        state.confirmForeground(applicationActive:false, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "迟到激活信号不能为已非前台的应用恢复确认")
        check(!state.permits(consoleUserCurrent:true), "唤醒或用户切换撤销后不得自动恢复")
        print("会话状态10项回归通过；正向数据保护信号不授予会话权限。")
    }
}
