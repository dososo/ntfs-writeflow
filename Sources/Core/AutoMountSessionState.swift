// 数据保护可用并不等于图形屏幕已解锁；正向授权只来自当前控制台前台确认。
struct AutoMountSessionState {
    private(set) var protectedDataAvailable = false
    private(set) var foregroundConfirmed = false
    private(set) var protectedDataBlocked = false
    private(set) var sleeping = false
    private(set) var workspaceActive = true

    mutating func observeProtectedData(available: Bool) {
        protectedDataAvailable = available
        if !available { protectedDataBlocked = true; revoke() }
    }
    mutating func protectedDataBecameAvailable(available: Bool) {
        observeProtectedData(available: available)
        if available { protectedDataBlocked = false }
    }
    mutating func observeConsoleUser(current: Bool) {
        if !current { revoke() }
    }
    mutating func setSleeping(_ value: Bool) { sleeping = value; revoke() }
    mutating func setWorkspaceActive(_ value: Bool) { workspaceActive = value; revoke() }
    mutating func confirmForeground(applicationActive: Bool, consoleUserCurrent: Bool, protectedDataAvailable: Bool) {
        observeProtectedData(available: protectedDataAvailable)
        foregroundConfirmed = applicationActive && consoleUserCurrent && protectedDataAvailable
            && !protectedDataBlocked && !sleeping && workspaceActive
    }
    mutating func revoke() { foregroundConfirmed = false }
    func permits(consoleUserCurrent: Bool) -> Bool {
        foregroundConfirmed && protectedDataAvailable && consoleUserCurrent
            && !protectedDataBlocked && !sleeping && workspaceActive
    }
}

struct AutoMountSessionSnapshot {
    let applicationActive: Bool
    let consoleUserCurrent: Bool
    let protectedDataAvailable: Bool
}
