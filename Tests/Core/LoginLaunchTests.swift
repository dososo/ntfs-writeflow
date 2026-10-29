import AppKit
@main enum LoginLaunchTests {
    static func main() {
        precondition(LoginLaunchService.isLoginLaunch(eventID: kAEOpenApplication, reason: keyAELaunchedAsLogInItem))
        precondition(!LoginLaunchService.isLoginLaunch(eventID: kAEOpenDocuments, reason: keyAELaunchedAsLogInItem))
        precondition(!LoginLaunchService.isLoginLaunch(eventID: kAEOpenApplication, reason: nil))
        precondition(!LoginLaunchService.isLoginLaunch(eventID: nil, reason: nil))
        print("登录启动判定4项通过；未注册或修改系统登录项。")
    }
}
