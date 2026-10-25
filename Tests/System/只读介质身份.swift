import Foundation
import IOKit
import Darwin

// 只读取指定 BSD 媒体的注册身份，供新建镜像测试核对，不执行设备写入。
guard CommandLine.arguments.count == 2,
      let name = CommandLine.arguments.last,
      name.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil,
      let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else {
    fputs("必须提供合法的 BSD 媒体名称。\n", stderr)
    exit(2)
}
let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
guard media != IO_OBJECT_NULL else { exit(3) }
defer { IOObjectRelease(media) }
var identity: UInt64 = 0
guard IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS,
      identity != 0, IORegistryEntryInPlane(media, kIOServicePlane) != 0 else { exit(4) }
print(identity)
