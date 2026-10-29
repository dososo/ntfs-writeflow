import Foundation
import Darwin
@main enum IsolationTests {
 static func main() throws {
    precondition(BenchmarkIsolation.isCanonical("/private/tmp/测试"))
    precondition(!BenchmarkIsolation.isCanonical("/private/tmp/../测试"))
    precondition(!BenchmarkIsolation.isCanonical("/private//tmp/测试"))
    let helperPath=PrivilegedMountConfiguration.namespace+"/\(geteuid())/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/volume"
    let helper=MountedFileSystem(type:"blntfs",source:"/dev/disk99",mountPoint:helperPath,identity:"root-mount",ownerID:0,isReadOnly:false)
    precondition(BenchmarkIsolation.helperAnchor(mounted:helper,caller:geteuid(),sameMountCount:1)==PrivilegedMountConfiguration.namespace+"/\(geteuid())")
    precondition(BenchmarkIsolation.helperAnchor(mounted:helper,caller:geteuid()+1,sameMountCount:1)==nil)
    precondition(BenchmarkIsolation.helperAnchor(mounted:helper,caller:geteuid(),sameMountCount:2)==nil)
    let forged=MountedFileSystem(type:"blntfs",source:"/dev/disk99",mountPoint:helperPath.replacingOccurrences(of:"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",with:"not-a-token"),identity:"root-mount",ownerID:0,isReadOnly:false)
    precondition(BenchmarkIsolation.helperAnchor(mounted:forged,caller:geteuid(),sameMountCount:1)==nil)
    let uid=geteuid(),good=BenchmarkIsolation.Node(owner:geteuid(),mode:0o700,emptyACL:true,identity:"apfs")
    precondition(BenchmarkIsolation.permits(anchor:good,volumeIdentity:"ntfs",sameMountCount:1,caller:uid))
    var bad=good;bad.owner=0
    precondition(!BenchmarkIsolation.permits(anchor:bad,volumeIdentity:"ntfs",sameMountCount:1,caller:uid))
    bad=good;bad.mode=0o777
    precondition(!BenchmarkIsolation.permits(anchor:bad,volumeIdentity:"ntfs",sameMountCount:1,caller:uid))
    bad=good;bad.emptyACL=false
    precondition(!BenchmarkIsolation.permits(anchor:bad,volumeIdentity:"ntfs",sameMountCount:1,caller:uid))
    precondition(!BenchmarkIsolation.permits(anchor:good,volumeIdentity:"apfs",sameMountCount:1,caller:uid))
    precondition(!BenchmarkIsolation.permits(anchor:good,volumeIdentity:"ntfs",sameMountCount:2,caller:uid))
    let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("writeflow-isolation-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let fd=open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);precondition(fd>=0);defer { close(fd) }
    precondition(BenchmarkIsolation.emptyACL(fd))
    let chmod=Process();chmod.executableURL=URL(fileURLWithPath:"/bin/chmod");chmod.arguments=["+a","everyone allow readattr",root.path]
    try chmod.run();chmod.waitUntilExit();precondition(chmod.terminationStatus==0)
    precondition(!BenchmarkIsolation.emptyACL(fd))
    try HelperNamespace.setACL(fd,allowedUser:geteuid())
    try HelperNamespace.verifyACL(fd,allowedUser:geteuid())
    do { try HelperNamespace.verifyACL(fd,allowedUser:nil);preconditionFailure("用户ACL不能当作空ACL") } catch {}
    let extra=Process();extra.executableURL=URL(fileURLWithPath:"/bin/chmod");extra.arguments=["+a","everyone allow write",root.path]
    try extra.run();extra.waitUntilExit();precondition(extra.terminationStatus==0)
    do { try HelperNamespace.verifyACL(fd,allowedUser:geteuid());preconditionFailure("不能接受额外写ACL") } catch {}
    print("隔离策略6种拒绝/允许边界及真实空ACL→额外ACL拒绝通过；新目录保留：\(root.path)")
 }
}
