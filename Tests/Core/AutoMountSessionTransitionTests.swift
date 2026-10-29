import Foundation

@main enum SessionTransitionTests {
    static func main() {
        var state = AutoMountSessionState()
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        // 模拟willUnavailable先收到，系统属性仍为true，以及紧随其后的前台通知。
        state.observeProtectedData(available:false)
        state.observeProtectedData(available:true)
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        guard !state.permits(consoleUserCurrent:true) else {
            print("失败：负向数据保护事件后，尚未收到恢复事件却被属性true和前台确认重新授予")
            exit(1)
        }
        func check(_ value: Bool, _ reason: String) { if !value { print("失败：\(reason)"); exit(1) } }
        state.protectedDataBecameAvailable(available:false)
        check(!state.permits(consoleUserCurrent:true), "错误的恢复事件不能解锁")
        state.protectedDataBecameAvailable(available:true)
        check(!state.permits(consoleUserCurrent:true), "恢复事件自身不授予")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(state.permits(consoleUserCurrent:true), "恢复后新的前台确认可以允许")
        state.setSleeping(true)
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "睡眠期间迟到前台确认不能授予")
        state.setSleeping(false)
        check(!state.permits(consoleUserCurrent:true), "唤醒自身不能授予")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(state.permits(consoleUserCurrent:true), "唤醒后需新的前台确认")
        state.setWorkspaceActive(false)
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "工作区失活期间前台通知不得授予")
        state.setWorkspaceActive(true)
        check(!state.permits(consoleUserCurrent:true), "工作区恢复自身不得授予")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        state.observeConsoleUser(current:false)
        state.observeConsoleUser(current:true)
        check(!state.permits(consoleUserCurrent:true), "控制台身份恢复不得复活旧确认")
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        state.setSleeping(true); state.setWorkspaceActive(false); state.setSleeping(false)
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "唤醒不能解除工作区失活闭锁")
        state.setWorkspaceActive(true); state.observeProtectedData(available:false)
        state.confirmForeground(applicationActive:true, consoleUserCurrent:true, protectedDataAvailable:true)
        check(!state.permits(consoleUserCurrent:true), "工作区恢复不能解除数据保护闭锁")
        print("会话组合12项通过：数据保护过渡、睡眠唤醒、工作区恢复、控制台失效及交叉闭锁。")
    }
}
