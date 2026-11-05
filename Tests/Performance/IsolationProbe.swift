import Foundation
import Darwin

// 两种隔离分开核验；助手ACL直接复用生产实现，不新增授权。
struct BenchmarkIsolation {
    struct Node {
        var owner: UInt32
        var mode: UInt16
        var emptyACL: Bool
        var identity: String
    }
    static func permits(anchor: Node, volumeIdentity: String, sameMountCount: Int, caller: UInt32) -> Bool {
        anchor.owner == caller && anchor.mode == 0o700 && anchor.emptyACL &&
        anchor.identity != volumeIdentity && sameMountCount == 1
    }
    static func emptyACL(_ descriptor: Int32) -> Bool {
        do { try HelperNamespace.verifyACL(descriptor,allowedUser:nil);return true }
        catch { return false }
    }
    static func helperAnchor(mounted: MountedFileSystem,caller: UInt32,sameMountCount: Int) -> String? {
        guard caller>=501,caller != UInt32.max,mounted.type=="blntfs",mounted.ownerID==0,sameMountCount==1,
              mounted.source.range(of:#"^/dev/disk[0-9]+(s[0-9]+)*$"#,options:.regularExpression) != nil,
              PrivilegedMountConfiguration.token(mountPoint:mounted.mountPoint,userID:caller) != nil else { return nil }
        return PrivilegedMountConfiguration.namespace+"/\(caller)"
    }
    private static func refuse(_ reason: String) -> [String:Any]? {
        FileHandle.standardError.write(Data(("性能隔离拒绝："+reason+"\n").utf8));return nil
    }
    static func isCanonical(_ path: String) -> Bool {
        let pieces=path.split(separator:"/",omittingEmptySubsequences:false)
        return path.hasPrefix("/") && pieces.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func proof(path: String, mounted: MountedFileSystem) -> [String: Any]? {
        guard mounted.type == "blntfs", isCanonical(path),
              path.hasPrefix(mounted.mountPoint+"/") || path == mounted.mountPoint else { return refuse("路径或提供方不符") }
        var mounts: UnsafeMutablePointer<statfs>?
        let count=getmntinfo(&mounts,MNT_NOWAIT)
        guard count>0,let mounts else { return refuse("无法取得系统挂载列表") }
        var same=0
        for n in 0..<Int(count) {
            var value=mounts[n]
            let source=withUnsafeBytes(of:&value.f_mntfromname) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
            let identity="\(value.f_fsid.val.0):\(value.f_fsid.val.1)"
            if source==mounted.source || identity==mounted.identity { same+=1 }
        }
        let helper=helperAnchor(mounted:mounted,caller:geteuid(),sameMountCount:same)
        guard helper != nil || mounted.ownerID==geteuid() else { return refuse("root挂载未处于可信助手namespace") }
        var current=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard current>=0 else { return refuse("无法打开系统根目录") }
        defer { close(current) }
        var rootStat=stat()
        guard fstat(current,&rootStat)==0,rootStat.st_uid==0,rootStat.st_mode & 0o022 == 0,emptyACL(current) else { return refuse("系统根目录权限不符") }
        var partial="",anchor:[String:Any]?
        for component in path.split(separator:"/") {
            let next=openat(current,String(component),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next>=0 else { return refuse("逐级打开目录失败") }
            close(current);current=next;partial+="/"+component
            var st=stat()
            guard fstat(current,&st)==0,let fs=MountedFileSystemReader.read(descriptor:current) else { return refuse("逐级目录属性不可读") }
            if partial==mounted.mountPoint {
                guard fs==mounted,anchor != nil else { return refuse("挂载根与FD信息不同，或缺隔离祖先") }
            } else if !partial.hasPrefix(mounted.mountPoint+"/") {
                if let helper {
                    guard st.st_uid==0,fs.type=="apfs",fs.identity != mounted.identity,st.st_mode & 0o022 == 0 else { return refuse("助手祖先非独立安全root目录") }
                    if partial==helper {
                        guard st.st_mode & 0o777 == 0o700 else { return refuse("助手用户层模式不是root700") }
                        do { try HelperNamespace.verifyACL(current,allowedUser:geteuid()) }
                        catch { return refuse("助手用户层ACL不符合生产白名单") }
                        anchor=["path":partial,"device":st.st_dev,"inode":st.st_ino,"uid":st.st_uid,"mode":st.st_mode & 0o777,"identity":fs.identity,"isolation_kind":"helper-root-acl","caller_uid":geteuid()]
                    } else {
                        if partial==PrivilegedMountConfiguration.namespace || partial==URL(fileURLWithPath:mounted.mountPoint).deletingLastPathComponent().path {
                            guard st.st_mode & 0o777 == 0o755 else { return refuse("助手base或UUID层模式不是root755") }
                        }
                        do { try HelperNamespace.verifyACL(current,allowedUser:nil) }
                        catch { return refuse("助手安全祖先含额外ACL") }
                    }
                } else {
                    // 公共祖先只允许系统/当前UID拥有；公开可写祖先必须有sticky且由root拥有。
                    guard st.st_uid==0 || st.st_uid==geteuid(),
                          st.st_mode & 0o022 == 0 || (st.st_uid==0 && st.st_mode & 0o1000 != 0),
                          emptyACL(current) else { return refuse("祖先权限或ACL不符") }
                    let node=Node(owner:st.st_uid,mode:UInt16(st.st_mode & 0o777),emptyACL:true,identity:fs.identity)
                    if fs.type == "apfs" && permits(anchor:node,volumeIdentity:mounted.identity,sameMountCount:same,caller:geteuid()) {
                        anchor=["path":partial,"device":st.st_dev,"inode":st.st_ino,"uid":st.st_uid,"mode":st.st_mode & 0o777,"identity":fs.identity,"isolation_kind":"direct-uid","caller_uid":geteuid()]
                    }
                }
            } else {
                guard fs==mounted else { return refuse("挂载卷内出现其他文件系统") }
            }
        }
        guard var proof=anchor else { return refuse("缺少有效隔离祖先") }
        proof["schema"]=1;proof["mount_identity"]=mounted.identity;proof["mount_point"]=mounted.mountPoint
        proof["source"]=mounted.source;proof["same_mount_count"]=same
        return proof
    }
}
