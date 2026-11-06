import Foundation

@main enum PhysicalMediaEvidenceTests {
    static func main() throws {
        guard (1...3).contains(CommandLine.arguments.count) else { exit(2) }
        let info: [String: Any]
        let origin: String
        if CommandLine.arguments.count == 1 {
            info = ["Internal": false, "BusProtocol": "USB", "SystemImage": false]
            origin = "明确模拟fixture（仅三个字段，非实测）"
        } else {
            info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! [String: Any]
            origin = CommandLine.arguments.count == 3 ? "实际plist与独立DA/IOMedia快照回放" : "实际plist加构造DA/IOMedia（非完整实测）"
        }
        precondition(info["VirtualOrPhysical"] == nil && info["BusProtocol"] as? String == "USB")
        let external = ["Physical Interconnect": "USB", "Physical Interconnect Location": "External"]
        var imageInfo = info; imageInfo["BusProtocol"] = "Disk Image"
        let image = ["Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File"]
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func classify(_ source: [String: Any] = info, _ internalDevice: Bool? = false,
                      _ protocolName: String? = "USB", _ properties: [String: Any]? = external) -> Bool? {
            PhysicalMediaEvidence.virtual(info: source, daInternal: internalDevice, daProtocol: protocolName, properties: properties)
        }
        check(classify() == false, "缺可选kind键不妨碍构造DA/IOMedia正向互证")
        check(classify(imageInfo, false, "Virtual Interface", image) == true, "明确File镜像不能作实盘")
        check(classify(info, false, "USB", nil) == nil, "缺协议证据为unknown")
        check(classify(info, false, "USB", ["Physical Interconnect": "USB"]) == nil, "缺location为unknown")
        check(classify(info, nil) == nil, "缺DA internal为unknown")
        var missing = info; missing.removeValue(forKey: "Internal")
        check(classify(missing) == nil, "缺真实internal不可默认为外部")
        check(classify(info, true) == nil, "DA和diskutil冲突为unknown")
        check(classify(info, false, "FireWire") == nil, "DA和IOMedia协议冲突为unknown")
        check(classify(info, false, "USB", ["Physical Interconnect": "USB", "Physical Interconnect Location": "File"]) == nil, "矛盾File/USB不猜")
        check(classify(info, false, "Virtual Interface", ["Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "External"]) == nil, "矛盾virtual/external不猜")
        check(classify(info, false, "Network", ["Physical Interconnect": "Network", "Physical Interconnect Location": "External"]) == nil, "未知协议不当实体")
        var contradictory = info; contradictory["VirtualOrPhysical"] = "Virtual"
        check(classify(contradictory) == nil, "旧kind与正向物理证据冲突为unknown")
        contradictory = imageInfo; contradictory["VirtualOrPhysical"] = "Physical"
        check(classify(contradictory, false, "Virtual Interface", image) == nil, "旧kind与镜像证据冲突为unknown")
        contradictory["VirtualOrPhysical"] = "Other"
        check(classify(contradictory) == nil, "未知旧kind不放行")
        var internalInfo = info; internalInfo["Internal"] = true; internalInfo["BusProtocol"] = "Apple Fabric"
        check(classify(internalInfo, true, "Apple Fabric", ["Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal"]) == false, "内部实体可识别，但既有internal gate仍拒写目标")
        check(PhysicalMediaEvidence.boolean(false) == false && PhysicalMediaEvidence.boolean("false") == nil && PhysicalMediaEvidence.boolean(0) == nil, "布尔必须真实CFBoolean")
        let unknown: Bool? = nil
        let unknownData = try JSONSerialization.data(withJSONObject: ["virtual": unknown as Any? ?? NSNull()])
        let unknownJSON = try JSONSerialization.jsonObject(with: unknownData) as! [String: Any]
        check(unknownJSON["virtual"] is NSNull, "unknown序列化保持null，不转换为physical")
        if CommandLine.arguments.count == 3 {
            let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
            let evidence = actual["physical_evidence"] as! [String: Any]
            check(classify(info, evidence["da_internal"] as? Bool, evidence["da_protocol"] as? String,
                ["Physical Interconnect": evidence["interconnect"]!, "Physical Interconnect Location": evidence["location"]!]) == false,
                "实际只读DA/IOMedia证据与原始plist回放为实体")
        } else {
            var explicit = info; explicit["VirtualOrPhysical"] = "Physical"
            check(classify(explicit) == false, "明确kind仍须与完整模拟物理证据互证")
        }
        print("物理判定通过：\(checks)项；来源：\(origin)；无挂载或用户文件内容IO。")
    }
}
