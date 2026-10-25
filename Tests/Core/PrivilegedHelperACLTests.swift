import Foundation
import Darwin

@main enum PrivilegedHelperACLTests {
    static func main() throws {
        let root = FileManager.default.currentDirectoryPath + "/build/helper-candidate/ACL验证-\(UUID().uuidString)"
        guard mkdir(root, 0o700) == 0 else { fatalError("无法创建本次测试目录") }
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { fatalError("无法打开本次测试目录") }
        let filePath = root + "/普通文件"
        let file = open(filePath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { fatalError("无法创建本次普通文件") }
        defer {
            close(file)
            close(directory)
            // 仅删除明确的测试文件与它的空目录，不递归。
            precondition(unlink(filePath) == 0, "测试文件清理失败")
            precondition(rmdir(root) == 0, "测试空目录清理失败")
        }
        var passed: [String] = []
        for (descriptor, name) in [(directory, "目录"), (file, "普通文件")] {
            try HelperNamespace.setACL(descriptor, allowedUser: nil)
            try HelperNamespace.verifyACL(descriptor, allowedUser: nil)
            passed.append("\(name)空扩展ACL真实设置与回读")
            do {
                try HelperNamespace.verifyACL(descriptor, allowedUser: geteuid())
                fatalError("缺少命名用户ACL不得通过")
            } catch let error as HelperFailure {
                precondition(error.message == "无法读取目录访问控制。")
                passed.append("\(name)缺少命名用户ACL仍拒绝")
            }

            try HelperNamespace.setACL(descriptor, allowedUser: geteuid())
            try HelperNamespace.verifyACL(descriptor, allowedUser: geteuid())
            passed.append("\(name)命名用户扩展ACL真实设置与回读")

            do {
                try HelperNamespace.verifyACL(descriptor, allowedUser: nil)
                fatalError("非空ACL不得当作空ACL通过")
            } catch let error as HelperFailure {
                precondition(error.message.contains("不符合当前用户隔离要求"))
                passed.append("\(name)异常授权不被当作空ACL")
            }

            let changed = try HelperNamespace.makeACL(geteuid())
            defer { acl_free(UnsafeMutableRawPointer(changed)) }
            var entry: acl_entry_t?
            precondition(acl_get_entry(changed, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0)
            var permissions: acl_permset_t?
            precondition(acl_get_permset(entry!, &permissions) == 0)
            precondition(acl_add_perm(permissions!, ACL_WRITE_DATA) == 0)
            precondition(acl_set_fd_np(descriptor, changed, ACL_TYPE_EXTENDED) == 0)
            do {
                try HelperNamespace.verifyACL(descriptor, allowedUser: geteuid())
                fatalError("额外写权限不得通过")
            } catch let error as HelperFailure {
                precondition(error.message.contains("不符合当前用户隔离要求"))
                passed.append("\(name)额外写权限被拒绝")
            }
            try HelperNamespace.setACL(descriptor, allowedUser: nil)
        }
        do {
            try HelperNamespace.verifyACL(-1, allowedUser: nil)
            fatalError("读取失败不得当作空ACL")
        } catch let error as HelperFailure {
            precondition(error.message == "无法读取目录访问控制。")
            passed.append("读取失败仍拒绝")
        }
        let report: [String: Any] = ["结果": "通过", "检查": passed, "数量": passed.count,
            "边界": "仅当前用户新建普通文件与目录；未改系统目录、未注册助手、未查询或操作设备；不是跨用户访问实测。"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/build/helper-candidate/扩展ACL验证结果.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
