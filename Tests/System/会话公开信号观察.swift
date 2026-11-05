import AppKit
import Darwin
import Foundation

// 只读诊断：受保护数据可用不等于图形屏幕已解锁，任何结果均不授权挂载。
@main
@MainActor
enum PublicSessionObservation {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count <= 2,
              let seconds = arguments.count == 2 ? Double(arguments[1]) : 10,
              seconds.isFinite, (1...300).contains(seconds) else {
            FileHandle.standardError.write(Data("用法：会话公开信号观察 [观察秒数，1至300，默认10]\n".utf8))
            exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let started = ProcessInfo.processInfo.systemUptime
        let record: @MainActor @Sendable (String) -> Void = { event in
            let entry: [String: Any] = [
                "事件": event,
                "受保护数据可用": app.isProtectedDataAvailable,
                "应用活动": app.isActive,
                "进程UID": getuid(),
                "已运行秒数": ProcessInfo.processInfo.systemUptime - started,
                "结论限制": "此状态不证明图形屏幕已解锁，不授权磁盘操作"
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
                FileHandle.standardError.write(Data("观察记录编码失败\n".utf8))
                exit(3)
            }
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }

        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        var observers: [(NotificationCenter, NSObjectProtocol)] = []
        let events: [(NotificationCenter, Notification.Name, String)] = [
            (appCenter, .NSApplicationProtectedDataWillBecomeUnavailable, "受保护数据将不可用"),
            (appCenter, .NSApplicationProtectedDataDidBecomeAvailable, "受保护数据已可用"),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, "工作区会话活动"),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, "工作区会话离开活动"),
            (workspaceCenter, NSWorkspace.willSleepNotification, "系统将睡眠"),
            (workspaceCenter, NSWorkspace.didWakeNotification, "系统已唤醒")
        ]
        for (center, name, event) in events {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { record(event) }
            }
            observers.append((center, observer))
        }

        record("初始快照")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        record("观察结束")
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
