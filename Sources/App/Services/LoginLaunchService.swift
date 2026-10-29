import AppKit
import ServiceManagement

@MainActor enum LoginLaunchService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var status: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .requiresApproval: return "等待在系统设置批准"
        case .notRegistered: return "未启用"
        case .notFound: return "系统未找到当前应用"
        @unknown default: return "系统返回未知状态"
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
        return isLoginLaunch(eventID: event?.eventID,
            reason: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue)
    }

    nonisolated static func isLoginLaunch(eventID: UInt32?, reason: UInt32?) -> Bool {
        eventID == kAEOpenApplication && reason == keyAELaunchedAsLogInItem
    }
}
