// 数据保护可用并不等于图形屏幕已解锁；正向授权只来自当前控制台前台确认。
struct AutoMountSessionState {
    private(set) var protectedDataAvailable = false
    private(set) var foregroundConfirmed = false

    mutating func observeProtectedData(available: Bool) {
        protectedDataAvailable = available
        if !available { foregroundConfirmed = false }
    }
    mutating func confirmForeground(applicationActive: Bool, consoleUserCurrent: Bool, protectedDataAvailable: Bool) {
        observeProtectedData(available: protectedDataAvailable)
        foregroundConfirmed = applicationActive && consoleUserCurrent && protectedDataAvailable
    }
    mutating func revoke() { foregroundConfirmed = false }
    func permits(consoleUserCurrent: Bool) -> Bool {
        foregroundConfirmed && protectedDataAvailable && consoleUserCurrent
    }
}
