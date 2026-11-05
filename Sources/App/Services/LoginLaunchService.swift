import AppKit
import ServiceManagement

enum LoginLaunchState: Sendable {
    case pending, enabled, requiresApproval, notRegistered, notFound, unknown

    var isEnabled: Bool { self == .enabled }
    var title: String {
        switch self {
        case .pending: return "尚未查询"
        case .enabled: return "已启用"
        case .requiresApproval: return "等待在系统设置批准"
        case .notRegistered: return "未启用"
        case .notFound: return "系统未找到当前应用"
        case .unknown: return "系统返回未知状态"
        }
    }
}

struct LoginLaunchContext: Sendable {
    let eventID: UInt32?
    let reason: UInt32?
    var wasLaunchedAtLogin: Bool { LoginLaunchService.isLoginLaunch(eventID:eventID,reason:reason) }
}

@MainActor enum LoginLaunchService {
    private(set) static var lastLaunchContext: LoginLaunchContext?
    // 同一次系统读取同时决定开关和文本，避免两次查询之间状态变化。
    static var state: LoginLaunchState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }

    // 必须在applicationDidFinishLaunching读取当前启动事件；不用持久偏好猜测启动原因。
    // Apple事件判定方法参考MIT项目LaunchAtLogin-Modern，归属见第三方组件说明。
    static var wasLaunchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let context = LoginLaunchContext(eventID:event?.eventID,
            reason:event?.paramDescriptor(forKeyword:keyAEPropData)?.enumCodeValue)
        lastLaunchContext = context
        return context.wasLaunchedAtLogin
    }

    nonisolated static func isLoginLaunch(eventID: UInt32?, reason: UInt32?) -> Bool {
        eventID == kAEOpenApplication && reason == keyAELaunchedAsLogInItem
    }
}
