import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import SystemConfiguration

private let sessionVerificationLogger = Logger(subsystem:"com.blteam.ntfsworkbench",category:"SessionVerification")

extension AppModel {
    // 白名单中不包含卷名、窗口标题、路径、账户名、用户文件或完整AppleEvent。
    func sessionVerificationRecord(_ event: String, seconds: Int? = nil, signal: String? = nil) -> [String:Any]? {
        guard let request = SessionVerificationRequest.parse(autoDefaults.object(forKey:SessionVerificationRequest.defaultsKey)) else { return nil }
        if verificationRequestID != request.id { verificationRequestID = request.id; verificationSequence = 0 }
        guard verificationSequence < 256 else { return nil }
        verificationSequence += 1
        if verificationBinarySHA == nil, let executable = Bundle.main.executableURL,
           let data = try? Data(contentsOf:executable,options:.mappedIfSafe) {
            verificationBinarySHA = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        }
        let console = CGSessionCopyCurrentDictionary() as? [String:Any]
        let callerSessionUID = (console?[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value
        var primaryUID = uid_t.max
        let hasPrimaryConsole = SCDynamicStoreCopyConsoleUser(nil,&primaryUID,nil) != nil
        let consoleUID: uid_t? = hasPrimaryConsole && primaryUID != uid_t.max ? primaryUID : nil
        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) }
        let visible = windows.filter { $0.isVisible && !$0.isMiniaturized }
        let knownRoles = ["main":"主窗口","diagnostics":"诊断","com_apple_SwiftUI_Settings_window":"设置"]
        let launch = LoginLaunchService.lastLaunchContext
        let state = autoRuntime?.loginState?() ?? LoginLaunchService.state
        return [
            "格式":2,"验收编号":request.id,"进程会话":verificationProcessID,"序号":verificationSequence,
            "事件":event,"时间":ISO8601DateFormatter().string(from:Date()),
            "PID":getpid(),"UID":getuid(),"EUID":geteuid(),
            "应用标识":Bundle.main.bundleIdentifier ?? "未知","版本":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知",
            "构建":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知","主程序SHA256":verificationBinarySHA ?? "未知",
            "原始事件ID":launch?.eventID.map { $0 as Any } ?? NSNull(),"原始启动原因":launch?.reason.map { $0 as Any } ?? NSNull(),
            "登录启动":launch.map { $0.wasLaunchedAtLogin as Any } ?? NSNull(),
            "登录项状态":state.title,"登录项已启用":state.isEnabled,
            "自动管理":autoEnabled,"前台确认":autoSession.foregroundConfirmed,"待确认":autoForegroundRequest != nil,
            "撤销代数":autoSessionRevocationEpoch,"工作区活动":autoSession.workspaceActive,
            "数据保护":autoSession.protectedDataAvailable,"数据保护闭锁":autoSession.protectedDataBlocked,"睡眠闭锁":autoSession.sleeping,
            "控制台UID":consoleUID.map { $0 as Any } ?? NSNull(),
            "调用进程会话UID":callerSessionUID.map { $0 as Any } ?? NSNull(),
            "调用会话在控制台":(console?[kCGSessionOnConsoleKey as String] as? Bool).map { $0 as Any } ?? NSNull(),
            "控制台当前用户":consoleUID == geteuid() && callerSessionUID == geteuid() && console?[kCGSessionOnConsoleKey as String] as? Bool == true
                && console?[kCGSessionLoginDoneKey as String] as? Bool == true,
            "应用活动":NSApp.isActive,"激活策略":NSApp.activationPolicy().rawValue,
            "可见内容窗数":visible.count,"最小化内容窗数":windows.filter(\.isMiniaturized).count,
            "内容窗角色":visible.map { knownRoles[$0.identifier?.rawValue ?? ""] ?? "其他" }.sorted(),
            "磁盘监控存在":diskMonitor != nil,"会话监控存在":autoSessionMonitor != nil,
            "采样秒数":seconds.map { $0 as Any } ?? NSNull(),"信号":signal.map { $0 as Any } ?? NSNull()
        ]
    }
    func recordSessionVerification(_ event: String, seconds: Int? = nil, signal: String? = nil) {
        guard let record = sessionVerificationRecord(event,seconds:seconds,signal:signal),
              let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys),
              let payload = String(data:data,encoding:.utf8) else { return }
        sessionVerificationLogger.notice("WF_SESSION \(payload, privacy:.public)")
    }
    func scheduleSessionVerificationSamples(event: String = "启动窗口采样", signal: String? = nil) {
        guard let request = SessionVerificationRequest.parse(autoDefaults.object(forKey:SessionVerificationRequest.defaultsKey)) else { return }
        Task { @MainActor [weak self] in
            var previous = 0
            for second in [1,3,8] {
                do { try await Task.sleep(for:.seconds(second - previous)) } catch { return }
                guard let self, SessionVerificationRequest.parse(self.autoDefaults.object(forKey:SessionVerificationRequest.defaultsKey))?.id == request.id else { return }
                self.recordSessionVerification(event,seconds:second,signal:signal)
                previous = second
            }
        }
    }
}
