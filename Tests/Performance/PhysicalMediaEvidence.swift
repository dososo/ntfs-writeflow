import Foundation

// true=有证据的镜像，false=有互证的实体；缺失或冲突为nil，原physical gate继续拒绝nil。
enum PhysicalMediaEvidence {
    static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    static func virtual(info: [String: Any], daInternal: Bool?, daProtocol: String?,
                        properties: [String: Any]?) -> Bool? {
        guard let internalDisk = boolean(info["Internal"]), daInternal == internalDisk,
              let daProtocol, let bus = properties?["Physical Interconnect"] as? String,
              let location = properties?["Physical Interconnect Location"] as? String else { return nil }
        let kind: String?
        if let value = info["VirtualOrPhysical"] {
            guard let text = value as? String, ["Physical", "Virtual"].contains(text) else { return nil }
            kind = text
        } else { kind = nil }
        if bus == "Virtual Interface", location == "File" {
            guard kind != "Physical", ["Virtual Interface", "Disk Image"].contains(daProtocol),
                  info["BusProtocol"] == nil || ["Virtual Interface", "Disk Image"].contains(info["BusProtocol"] as? String ?? "") else { return nil }
            return true
        }
        let physical = ["USB", "FireWire", "Thunderbolt", "SATA", "SAS", "PCI-Express", "Apple Fabric"]
        guard kind != "Virtual", physical.contains(bus), daProtocol == bus,
              location == (internalDisk ? "Internal" : "External"),
              info["BusProtocol"] == nil || info["BusProtocol"] as? String == bus,
              boolean(info["SystemImage"]) != true else { return nil }
        return false
    }
}
