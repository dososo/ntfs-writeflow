import Foundation

@main enum FSKitWriteReadinessTests {
    @MainActor static func main() throws {
        let token = "ABCDEFAB-2222-4333-8444-555555555555"
        let old = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        var count = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); count += 1 }
        func rejects(_ text: String, _ work: () throws -> Void) {
            do { try work(); fatalError(text) } catch { count += 1 }
        }
        for (major, minor, required) in [(13, 0, false), (15, 3, false), (15, 4, true), (25, 9, true), (26, 0, false)] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
            check(FSKitWriteReadiness.requires(backend: .fsKit, readOnly: false, on: version) == required, "旧FSKit RW专用")
            check(!FSKitWriteReadiness.requires(backend: .fsKit, readOnly: true, on: version), "RO不需要回执")
            check(!FSKitWriteReadiness.requires(backend: .macFUSE, readOnly: false, on: version), "macFUSE不误伤")
        }
        let option = try FSKitWriteReadiness.option(token: token)
        check(option == "writeflow-ready-token=" + token, "固定许可选项")
        check(try FSKitWriteReadiness.token(fromOption: option) == token, "选项解码")
        for preparing in [true, false] {
            let name = try preparing ? FSKitWriteReadiness.prepareName(token: token) : FSKitWriteReadiness.statusName(token: token)
            check(name.utf8.count < 127, "名称不超过系统边界")
            check(try FSKitWriteReadiness.token(fromName: name, preparing: preparing) == token, "名称解码")
            rejects("不能互换准备与被动查询") { _ = try FSKitWriteReadiness.token(fromName: name, preparing: !preparing) }
        }
        for bad in [token.lowercased(), token + "\n", "../" + token, "", token + ",rw"] {
            rejects("非法token不能生成选项") { _ = try FSKitWriteReadiness.option(token: bad) }
            rejects("非法token不能生成名称") { _ = try FSKitWriteReadiness.prepareName(token: bad) }
            rejects("非法选项不能解码") { _ = try FSKitWriteReadiness.token(fromOption: "writeflow-ready-token=" + bad) }
        }
        let data = try FSKitWriteReadiness.receipt(token: token, mediaID: UInt64.max)
        check(try FSKitWriteReadiness.validate(data, token: token, mediaID: UInt64.max).writable, "UInt64完整范围回执")
        for text in ["{}", "[]", "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":false}",
                     "{\"schema\":true,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":true}",
                     "{\"schema\":1.0,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":true}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":true,\"writable\":true}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":1}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":true,\"extra\":0}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":9,\"writable\":false,\"writable\":true}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":0,\"writable\":true}",
                     "{\"schema\":1,\"token\":\"\(token)\",\"mediaID\":18446744073709551616,\"writable\":true}"] {
            rejects("异常JSON不能证明写入就绪") { _ = try FSKitWriteReadiness.validate(Data(text.utf8), token: token, mediaID: 9) }
        }
        rejects("超长JSON") { _ = try FSKitWriteReadiness.validate(Data(repeating: 32, count: 1025), token: token, mediaID: 9) }
        rejects("介质绑定变化") { _ = try FSKitWriteReadiness.validate(data, token: token, mediaID: 9) }
        rejects("token绑定变化") { _ = try FSKitWriteReadiness.validate(data, token: UUID().uuidString, mediaID: UInt64.max) }
        let path = PrivilegedMountConfiguration.namespace + "/501/\(token)/volume"
        let kernel = MountedFileSystem(type: "blntfs", source: "/dev/disk99s1", mountPoint: path, identity: "1:2", ownerID: 0, isReadOnly: false)
        let info: [String: Any] = ["DeviceIdentifier":"disk99s1", "ParentWholeDisk":"disk99", "FilesystemType":"ntfs", "MountPoint":path, "Internal":false, "Ejectable":true, "WritableMedia":true, "WritableVolume":true, "TotalSize":4096]
        func fresh(_ fs: MountedFileSystem = kernel, version: OperatingSystemVersion = old) -> VolumeRecord {
            VolumeRecord(info: info, mediaRegistryID: 9, wholeMediaRegistryID: 8, mountedFileSystem: fs,
                         writeReadinessRequired: StorageBackend.requiresWriteReadiness(on: version))!
        }
        let ready = PrivilegedMountResult(token: token, mountPoint: path, deviceID: "disk99s1", mediaRegistryID: 9,
            wholeMediaRegistryID: 8, fileSystemIdentity: "1:2", readOnly: false, backend: .fsKit, writeReady: true)
        check(fresh().access == .writeNotReady && fresh().canOfferUnmount, "首次失败仍显示未就绪并允许卸载")
        check(DiskService.applyingWriteReadiness([ready], to: fresh(), userID: 501).access == .readWrite, "匹配的被动真回执才显示可写")
        let previouslyReady = DiskService.applyingWriteReadiness([ready], to: fresh(), userID: 501)
        check(DiskService.applyingWriteReadiness([], to: previouslyReady, userID: 501).access == .writeNotReady, "本次查询失败会撤销已有true，不沿用缓存")
        for _ in 0..<2 {
            check(DiskService.applyingWriteReadiness([], to: fresh(), userID: 501).access == .writeNotReady, "刷新/重启无缓存真值不能变绿")
        }
        var changed = ready; changed.writeReady = false
        check(DiskService.applyingWriteReadiness([changed], to: fresh(), userID: 501).access == .writeNotReady, "显式失败不绿")
        changed.writeReady = nil
        check(DiskService.applyingWriteReadiness([changed], to: fresh(), userID: 501).access == .writeNotReady, "旧助手缺字段不绿")
        check(DiskService.applyingWriteReadiness([ready,ready], to: fresh(), userID: 501).access == .writeNotReady, "重复回执拒绝")
        let conflicting = PrivilegedMountResult(token: UUID().uuidString, mountPoint: path, deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true)
        check(DiskService.applyingWriteReadiness([ready,conflicting], to: fresh(), userID: 501).access == .writeNotReady, "同实例包含矛盾票据不能选其中一条通过")
        check(DiskService.applyingWriteReadiness([ready], to: fresh(), userID: 502).access == .writeNotReady, "其他用户票据不复用")
        for changed in [PrivilegedMountResult(token: UUID().uuidString, mountPoint: path, deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk99s1",mediaRegistryID:10,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:10,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:3",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:true,backend:.fsKit,writeReady:true)] {
            check(DiskService.applyingWriteReadiness([changed], to: fresh(), userID: 501).access == .writeNotReady, "介质/FSID/token/模式异常拒绝复用")
        }
        for changed in [PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk100s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path + "/other",deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.fsKit,writeReady:true),
                        PrivilegedMountResult(token:token,mountPoint:path,deviceID:"disk99s1",mediaRegistryID:9,wholeMediaRegistryID:8,fileSystemIdentity:"1:2",readOnly:false,backend:.macFUSE,writeReady:true)] {
            check(DiskService.applyingWriteReadiness([changed], to: fresh(), userID: 501).access == .writeNotReady, "设备/路径/后端错配不能变绿")
        }
        let badSource = MountedFileSystem(type:"blntfs",source:"/dev/disk100s1",mountPoint:path,identity:"1:2",ownerID:0,isReadOnly:false)
        check(DiskService.applyingWriteReadiness([ready], to: fresh(badSource), userID: 501).access == .writeNotReady, "来源错配的旧专用blntfs不能变绿")
        let legacy = MountedFileSystem(type:"macfuse",source:kernel.source,mountPoint:path,identity:kernel.identity,ownerID:0,isReadOnly:false)
        check(fresh(legacy).access == .readWrite, "macFUSE模式不误伤")
        let encoded = try JSONEncoder().encode(ready)
        check(try JSONDecoder().decode(PrivilegedMountResult.self, from: encoded).writeReady == true, "新结果字段可传输")
        var oldResult = try JSONSerialization.jsonObject(with: encoded) as! [String:Any]
        oldResult.removeValue(forKey: "writeReady")
        let oldData = try JSONSerialization.data(withJSONObject: oldResult)
        check(try JSONDecoder().decode(PrivilegedMountResult.self, from: oldData).writeReady == nil, "旧结果缺字段保持未知")
        let modern = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        check(fresh(version: modern).access == .readWrite, "现代FSKit不误伤")
        let model = AppModel(defaults: UserDefaults(suiteName: "writeflow.readiness.\(UUID().uuidString)")!)
        model.apply(DiskSnapshot(records: [previouslyReady], unreadableCount: 0))
        check(model.selectedVolume?.access == .readWrite, "真实AppModel接收已就绪快照")
        model.apply(DiskSnapshot(records: [fresh()], unreadableCount: 0))
        check(model.selectedVolume?.access == .writeNotReady && model.selectedVolume?.canOfferUnmount == true, "真实AppModel刷新撤销绿色并保留卸载")
        let restarted = AppModel(defaults: UserDefaults(suiteName: "writeflow.readiness.restart.\(UUID().uuidString)")!)
        restarted.apply(DiskSnapshot(records: [fresh()], unreadableCount: 0))
        check(restarted.selectedVolume?.access == .writeNotReady, "重建真实AppModel无本地缓存真值")
        let ro = MountedFileSystem(type:"ntfs",source:kernel.source,mountPoint:path,identity:kernel.identity,ownerID:0,isReadOnly:true)
        check(fresh(ro).access == .readOnly, "原生RO不伪装成未就绪")
        check(!kernel.isReadOnly && fresh().access != .readOnly, "不伪造内核只读事实")
        print("通过：\(count)项协议、App准备状态及真实模型回归；未枚举设备、连接XPC或请求挂载。")
    }
}
