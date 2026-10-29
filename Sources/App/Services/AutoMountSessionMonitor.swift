import AppKit

// 所有状态改变在queue.main同步交付；不把确认排入可越过撤销的Task。
enum AutoMountSessionEvent: Sendable {
    case foreground, workspaceResigned, workspaceActive, willSleep, didWake
    case protectedDataUnavailable, protectedDataAvailable, screenLocked, screenUnlocked
}

@MainActor final class AutoMountSessionMonitor {
    private let appCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let receive: @MainActor (AutoMountSessionEvent) -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation: UInt64 = 0

    init(appCenter: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         receive: @escaping @MainActor (AutoMountSessionEvent) -> Void) {
        self.appCenter = appCenter; self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter; self.receive = receive
    }
    func start() {
        guard observers.isEmpty else { return }
        generation &+= 1
        let epoch = generation
        let signals: [(NotificationCenter, Notification.Name, AutoMountSessionEvent)] = [
            (appCenter, NSApplication.didBecomeActiveNotification, .foreground),
            (appCenter, .NSApplicationProtectedDataWillBecomeUnavailable, .protectedDataUnavailable),
            (appCenter, .NSApplicationProtectedDataDidBecomeAvailable, .protectedDataAvailable),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .workspaceResigned),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .workspaceActive),
            (workspaceCenter, NSWorkspace.willSleepNotification, .willSleep),
            (workspaceCenter, NSWorkspace.didWakeNotification, .didWake),
            (distributedCenter, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (distributedCenter, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        ]
        for (center, name, event) in signals {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == epoch, !self.observers.isEmpty else { return }
                    self.receive(event)
                }
            }
            observers.append((center, token))
        }
    }
    func stop() {
        generation &+= 1
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
