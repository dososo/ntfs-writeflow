import Foundation
import Darwin
import Security

@main enum PrivilegedHelperPolicyTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            count += 1
        }
        let token = UUID().uuidString
        let base = PrivilegedMountConfiguration.namespace
        check(PrivilegedMountConfiguration.token(mountPoint: "\(base)/501/\(token)/volume", userID: 501) == token,
              "当前用户的严格路径应能提取凭据")
        for path in ["\(base)/502/\(token)/volume", "\(base)/501/../\(token)/volume",
                     "\(base)/501/\(token)/volume/", "\(base)/501/\(token)/other",
                     "\(base)-other/501/\(token)/volume", "\(base)/501/not-a-token/volume",
                     "/private/var/run/com.blteam.ntfsworkbench.mounts/501/\(token)/volume"] {
            check(PrivilegedMountConfiguration.token(mountPoint: path, userID: 501) == nil,
                  "不得接受其他用户、目录穿越、非标准或相邻路径")
        }
        for text in [PrivilegedMountConfiguration.clientRequirement, PrivilegedMountConfiguration.helperRequirement] {
            var requirement: SecRequirement?
            check(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess && requirement != nil,
                  "签名要求必须是系统可解析的有效要求")
            var ownCode: SecCode?
            check(SecCodeCopySelf([], &ownCode) == errSecSuccess && ownCode != nil, "应能检查本测试进程签名")
            check(SecCodeCheckValidity(ownCode!, [], requirement!) != errSecSuccess,
                  "临时测试程序不得满足正式应用或助手签名要求")
        }
        _ = NSXPCInterface(with: PrivilegedMountProtocol.self)
        count += 1

        let engine = PrivilegedMountEngine()
        do {
            _ = try engine.mount(Data(repeating: 0, count: 4097), userID: 501)
            fatalError("过大请求不得执行")
        } catch let error as HelperFailure { check(error.message == "挂载请求过大。", "应在读取设备之前拒绝") }
        for device in ["../disk0", "/dev/disk0", "disk0;id", "disk0\n", ""] {
            let request = PrivilegedMountRequest(deviceID: device, mediaRegistryID: 1,
                wholeMediaRegistryID: 2, mediaByteCount: 128, readOnly: true)
            do { _ = try HelperMedia(request); fatalError("无效设备标识不得查询设备") }
            catch let error as HelperFailure { check(error.message == "介质请求无效。", "应在系统命令之前拒绝") }
        }
        let noIdentity = PrivilegedMountRequest(deviceID: "disk9999", mediaRegistryID: 0,
            wholeMediaRegistryID: 2, mediaByteCount: 128, readOnly: true)
        do { _ = try HelperMedia(noIdentity); fatalError("缺失介质身份不得查询设备") }
        catch let error as HelperFailure { check(error.message == "介质请求无效。", "应在系统命令之前拒绝") }

        for userID: UInt32? in [nil, geteuid()] {
            let acl = try HelperNamespace.makeACL(userID)
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            check(acl_valid(acl) == 0, "目录访问控制必须有效")
            var entry: acl_entry_t?
            if userID == nil {
                check(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0, "普通目录不得含额外授权")
            } else {
                check(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 && entry != nil, "用户目录应仅有命名用户授权")
                var permissions: acl_permset_t?
                check(acl_get_permset(entry!, &permissions) == 0 && permissions != nil, "应能读取权限集合")
                check(acl_get_perm_np(permissions!, ACL_SEARCH) == 1 && acl_get_perm_np(permissions!, ACL_LIST_DIRECTORY) == 1,
                      "当前用户可遍历并列出目录")
                for permission in [ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    check(acl_get_perm_np(permissions!, permission) == 0, "不得授予用户目录修改或替换权")
                }
                check(acl_get_entry(acl, Int32(ACL_NEXT_ENTRY.rawValue), &entry) != 0, "不得含其他授权条目")
            }
        }
        let writableRequest = PrivilegedMountRequest(deviceID: "disk9999", mediaRegistryID: 1,
            wholeMediaRegistryID: 2, mediaByteCount: 128, readOnly: false)
        let ticket = HelperTicket(userID: 501, token: token, request: writableRequest, fileSystemIdentity: "1:2")
        let path = "\(base)/501/\(token)/volume"
        func mounted(_ identity: String = "1:2", owner: UInt32 = 0) -> MountedFileSystem {
            MountedFileSystem(type: "blntfs", source: "/dev/disk9999", mountPoint: path,
                identity: identity, ownerID: owner, isReadOnly: true)
        }
        check(PrivilegedMountEngine.matchesOwnedMount(ticket, path: path, mounted: mounted()),
              "读写请求降级只读后，原挂载必须仍可查询和回收")
        check(mounted().isReadOnly != ticket.request.readOnly, "降级不能作为符合原请求的成功挂载")
        check(!PrivilegedMountEngine.matchesOwnedMount(ticket, path: path, mounted: mounted("3:4")),
              "允许回收降级卷不得放松挂载实例核验")
        check(!PrivilegedMountEngine.matchesOwnedMount(ticket, path: path, mounted: mounted(owner: 501)),
              "允许回收降级卷不得放松系统所有权核验")
        print("后台助手策略 \(count) 项通过；未注册服务、未设置目录 ACL、未执行设备查询或挂载。")
    }
}
