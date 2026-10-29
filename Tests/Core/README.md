# 核心挂载与服务流程验证

以下命令均在仓库根目录执行。已验证环境为苹果芯片 Mac、macOS 26.6.2、Xcode 26.6；编译目标为 `arm64-apple-macos26.0`。本说明记录已执行结果；无设备回归已按当前共享前台弹出实现重新编译执行。真实设备验收另行记录。

## 核心挂载保护：23 项

`MountStateTests.swift` 使用构造的记录验证 `VolumeRecord`，不读取或操作实际设备。

```sh
mkdir -p build/core-tests
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  Sources/Core/VolumeRecord.swift Tests/Core/MountStateTests.swift \
  -o build/core-tests/挂载状态验证
build/core-tests/挂载状态验证
```

已通过的可检查行为：

1. `diskutil` 报告为其他驱动类型时，仍从内核状态识别实际 `blntfs` 挂载。
2. 内核只读标志优先于 `diskutil` 可写报告。
3. 自有临时目录挂载可以提供卸载入口。
4. 已挂载卷不能再次挂载。
5. 缺少内核挂载证据时拒绝卸载。
6. 内部卷拒绝卸载。
7. 缺少介质身份时拒绝卸载。
8. 卷标识缺失时，可凭稳定介质与真实挂载实例确认卸载目标。
9. 不接管其他驱动的挂载。
10. 挂载来源设备不符时拒绝卸载。
11. 父目录的文件系统状态不能冒充挂载根目录。
12. 外部、未挂载的 NTFS 卷可请求挂载。
13. 内部盘不能请求挂载。
14. 其他文件系统不能请求挂载。
15. 缺少稳定介质对象时拒绝挂载。
16. 驱动更换卷标识不会改变已绑定的介质身份。
17. 设备编号与卷标识相同，但介质对象已更换时拒绝旧身份。
18. 无独立介质容量字段时，容量变化拒绝旧身份。
19. 挂载后展示容量及卷标识变化，但 `IOKitSize` 相同时仍识别同一介质。
20. 展示容量 `totalBytes` 与稳定介质容量 `mediaByteCount` 分别保存。
21. 实际介质容量变化仍拒绝旧身份。
22. 卷标识缺失但稳定介质对象存在时，可进入挂载前核验。
23. 无法确认介质容量时拒绝挂载。

## 卸载序列：3 项

`UnmountSequenceTests.swift` 直接测试生产服务的 `DiskService.synchronizeAndUnmount`，仅替换同步及卸载系统调用闭包，不触及设备。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift \
  Sources/App/Services/PrivilegedMountClient.swift \
  -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/App/Services/AuthorizedDeviceHandle.swift \
  Sources/App/Services/DiskService.swift \
  Sources/App/Services/RetainedDiskBinding.swift \
  Sources/App/Services/MountedFileSystemReader.swift \
  Tests/Core/UnmountSequenceTests.swift \
  -o build/core-tests/卸载序列验证
build/core-tests/卸载序列验证
```

已通过：同步返回 `EIO` 时不调用卸载并报告保留挂载；成功时先同步后卸载、传入同一描述符且卸载标志为 `0`；卸载返回 `EBUSY` 时报告失败。

生产流程先复核介质身份、当前用户所有权及内核挂载实例，再以 `O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开根目录，执行 `fstatfs`、`fsync` 和 `funmount(fd, 0)`。此前用 `O_RDONLY` 打开根目录会让自身读引用阻止正常卸载，实际返回 `EBUSY`。事件描述符保留对象绑定且避免这一自占用；以下系统服务集成已实测同步和正常卸载成功。此流程不强制卸载，也不按可变设备编号或路径提交卸载。卷卸载成功不等于整盘已弹出。

## 真实系统服务集成：9 项

`MountServiceIntegration.swift` 直接调用应用生产使用的 `DiskService.record`、`mount` 与 `unmount`。它真实执行系统挂载、读取 `statfs` 并经 `funmount` 卸载；不伪造卷记录、不替换挂载实现、不绕过生产保护条件。

运行前必须已经安装并启用含 `writeflow-media-id` 身份门禁的签名扩展，完成门禁正反验证，并由发布验收流程开放 `AppCapabilities.directMountEnabled`。本入口不安装扩展、不修改能力开关；开关关闭时在创建镜像前退出。另需已有本机引擎构建产物 `build/engine/arm64/ntfsprogs/mkntfs` 与 `ntfscat`。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift \
  Sources/App/Services/PrivilegedMountClient.swift \
  -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/App/Services/AuthorizedDeviceHandle.swift \
  Sources/App/Services/DiskService.swift \
  Sources/App/Services/RetainedDiskBinding.swift \
  Sources/App/Services/MountedFileSystemReader.swift \
  Tests/Core/MountServiceIntegration.swift \
  -o build/core-tests/服务集成验证
build/core-tests/服务集成验证
```

入口不接受设备参数，只创建并格式化本次生成的 **128 MiB 普通文件镜像**，通过 `hdiutil attach -nomount -nobrowse` 附加。它核验镜像与返回设备的关联、容量及未挂载状态，再调用同一生产服务。镜像的 `diskutil Internal` 实测为 `false`，自然满足生产外部介质保护，未增加测试专用放行条件。磁盘仲裁的内部属性可能缺失，绑定层不以这个冗余字段推翻已复核的外部属性；介质对象与容量仍需匹配。

已通过的 9 项：

1. 新建镜像与生产介质保护核验。
2. 生产服务只读挂载，内核回读类型、所有者及访问模式。
3. 可写镜像以只读方式挂载后，创建文件明确返回 `EROFS`。
4. 重复挂载失败，原挂载实例保持不变。
5. 正常卸载后挂载点消失，整个镜像的摘要与挂载前相同。
6. 生产服务读写挂载，创建中文目录，写入、同步并复读 65,573 字节确定数据。
7. 保持文件打开时卸载明确返回 `EBUSY`，原挂载实例保持不变。
8. 关闭占用后正常卸载，再只读挂载，文件内容保持一致。
9. 正常卸载并分离镜像后，用独立 `ntfscat` 命令离线复读，内容一致。

成功运行证据位于仓库相对目录：

```text
build/服务集成验证/AF40192A-A4B4-4372-AF42-2A8068D6374C/结果.json
```

该报告记录 9 项通过、错误为空、测试设备已分离。每次重跑生成新的唯一目录，保留镜像、格式化与附加/分离日志、绑定来源诊断及结果报告。报告中的证据路径由运行位置生成；命令无需填写任何用户目录。

失败后的自动清理先重新核对 `hdiutil` 的镜像映射。若仍有挂载，仅在介质标识相同且实际挂载者为本应用时调用生产服务正常卸载，再正常分离；不强制卸载。清理失败会在报告中明确标记，不能据失败退出码推断设备已分离。不要用历史设备编号手工重试，更不要递归删除证据目录。曾出现的根目录读引用导致卸载失败的记录保留在旧证据中，后续已正常清理；最终通过记录使用事件描述符方案。

## 验证边界与恢复

这些结果覆盖核心判断、同步失败控制流及真实系统托管镜像服务流程。它们不证明图形界面人工验收、物理磁盘可靠性、突然拔盘、掉电或所有故障回写场景通过。`ntfscat` 使用同一 NTFS 引擎，不能替代 Windows 独立实现的互操作验证。同步失败测试通过闭包注入错误，不等于实际介质故障注入。

若需要撤回新挂载入口，最小产品回滚是关闭 `AppCapabilities.directMountEnabled`；已有挂载仍应按正常同步卸载流程处理。不要在设备仍挂载时移除扩展或清理挂载目录。

## 安全弹出策略与句柄回归：167 项

```sh
bash Tests/Core/run_eject_tests.sh
```

该脚本当前包含 58 项弹出入口/后置策略、32 项卷状态、60 项助手请求/句柄/重试策略和 17 项匿名 XPC 句柄与数组检查，共 167 项。它只测试构造记录、生产纯策略和普通文件/空设备的描述符边界，不创建磁盘映像，不枚举或修改磁盘。

- `EjectCapabilityTests.swift`：外部介质及本应用两类专用挂载目录的入口，拒绝内部/未知/无稳定身份/伪挂载来源/系统路径/同盘受保护分卷，及完整清单后置核对；另覆盖未分区整盘本身由 blntfs 挂载时的弹出、整盘内部和系统路径保护。
- `VolumeRecordTests.swift`：保留原卷状态与身份回归，整盘 fixture 使用对应的整盘 IOMedia 标识；稳定介质身份不依赖驱动返回的卷 UUID。
- `PrivilegedHelperEjectTests.swift`：请求用户、设备名、父子关系、介质标识、容量、挂载归属、保护路径、未卸载 blntfs、描述符类型和设备号、完整句柄数组匹配，以及过大/错误请求在设备访问前拒绝；仅 EBUSY 有界重试，每次重新核验，身份变化与其他错误立即停止。
- `PrivilegedHelperHandleTests.swift`：17 项真实匿名 XPC 句柄与数组传输回归；模拟接收端只验证句柄对应关系并关闭自己的副本，不执行同步、卸载或弹出。

这些结果不替代实际系统弹出、占用拒绝、同盘多分卷和真实介质图形界面验收，也不证明热拔插与掉电场景通过。

### 管理员服务真实弹出集成

`EjectSystemIntegration.swift` 拒绝外部参数，只在 `build/eject-0.1.1` 下新建两份 128 MiB 普通文件镜像，通过固定引擎格式化后附加。每个操作前检查本次镜像映射、介质身份和容量，测试错误身份拒绝、正常挂载卷占用拒绝、关闭占用后弹出，以及持续原始设备占用时有界拒绝、释放占用后的未挂载镜像弹出。成功需核对原 IOMedia 与镜像映射均消失。错误身份和未挂载弹出还比较整个镜像的 SHA-256。

这是有磁盘操作的集成测试，不能作为上述纯策略脚本的一部分自动运行。须先安装并授权当前正式候选管理员服务，再由发布验收者明确签名测试程序；助手始终保留原有精确签名要求，不为测试降低权限边界。测试不安装或注册服务。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift \
  Sources/App/Services/MountedFileSystemReader.swift \
  Sources/App/Services/PrivilegedMountClient.swift Sources/App/Services/AuthorizedDeviceHandle.swift \
  Sources/App/Services/DiskService.swift Sources/App/Services/RetainedDiskBinding.swift \
  Tests/Core/EjectSystemIntegration.swift \
  -o build/eject-0.1.1/弹出系统验收
```

编译不是执行授权。测试程序还需由相同开发者团队按正式应用标识签名才能连接已安装助手。普通临时签名无法通过；不得更改助手签名要求来让测试通过。运行前确保已有本机 `build/engine/arm64/ntfsprogs/mkntfs`，并已安装启用本版本正式 `blntfs` 扩展。测试显式携带本次介质身份，将新建镜像挂到当前用户专用目录；回读类型、来源、所有者和介质身份，通过生产 `DiskService.unmount` 卸载自有卷后，再执行助手准备与前台弹出。无需 Paragon。

每次执行保留唯一目录和完整结果，失败不会按旧设备编号自动清理、不会强制卸载。若报告残留，应先核对该报告的镜像映射及原介质身份，再正常恢复；不能拿历史编号操作设备。纯策略通过不代表此集成通过，以具体运行记录为准。

当前弹出流程使用前台提供的挂载根事件句柄：助手的 prepareEject 先核对所有根句柄与同盘挂载实例，再逐个正常同步/卸载；全部无挂载后，前台取得整盘只读原始设备句柄，并在应用进程后台队列调用共享 DiskEject 实现。该实现再次核验原 IOMedia、容量、字符设备号和空挂载清单，保持同一描述符提交弹出。管理员服务仅保留 prepareEject，最终 ioctl 不跨 XPC 交给后台进程。初版在卸载前提前打开原始整盘导致正常卸载后仍返回占用，单纯短暂重试没有解决；该失败保留，未当作通过。最终前台 ioctl 与固定盘回执实现已重新执行新建镜像集成，5 项通过，包括普通文件占用拒绝和额外原始设备占用约 3 秒后的明确拒绝，释放占用后正常弹出。具体本机证据不进入源码包；重跑仍需按上述条件执行。

### 当前系统弹出验证范围

最终候选对应的生产助手 prepare 与前台共享弹出实现，使用两份全新镜像完成以下 5 项；完整记录包含实际回复、原介质身份及映射回读，两份镜像均正常释放。后续修改仍须重新验收：

| 场景 | 检验结果 |
| --- | --- |
| 提交错误介质身份 | 明确拒绝，原对象与映射保留，整镜像摘要不变 |
| 保持普通测试文件打开 | 返回占用错误，原挂载实例保留，不强制卸载 |
| 关闭普通文件后重试 | 正常同步、卸载并弹出，原对象及映射消失 |
| 保持额外原始设备只读句柄 | 约 3 秒有界等待后明确拒绝，原介质及摘要保留 |
| 关闭额外句柄后弹出未挂载整盘 | 成功弹出，原对象及映射消失，摘要不变 |

0.1.1 历史镜像对照使用本机当时已有的 Paragon；0.1.2 测试已改为本应用 `blntfs` 和生产自有卷卸载流程，消除对其他驱动的依赖。历史对照只是当时独立测试条件，**应用本身的 NTFS 读写使用随包的开源引擎，不要求安装或购买 Paragon**。没有该驱动的开发者仍可构建与使用应用，但不能原样宣称这组第三方驱动对照已在自己的机器通过。

当前自动镜像集成未覆盖真实硬件热拔插/掉电、同一物理磁盘多分区实测、其他用户会话以及 Windows；这些应单独列验收，不从本组结果推断。本轮另已完成本应用 blntfs 演示镜像与真实固定外部盘的图形界面弹出验收；详细证据与候选签名记录由发布验收保存。

## 前台授权设备句柄：53 项无磁盘检查

```sh
mkdir -p build/eject-0.1.1
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/App/Services/AuthorizedDeviceHandle.swift Tests/Core/AuthorizedDeviceHandleTests.swift \
  -o build/eject-0.1.1/授权句柄策略验证
build/eject-0.1.1/授权句柄策略验证
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  Tests/Core/AuthorizedDeviceMessageTests.c -o build/eject-0.1.1/授权句柄消息验证
build/eject-0.1.1/授权句柄消息验证
```

24 项 Swift 检查覆盖严格整盘路径、换行与分区号拒绝、只读字符设备及 CLOEXEC；29 项 C 检查覆盖单描述符传输、多个描述符全部关闭、截断/无句柄/EOF 拒绝及无泄漏，开启地址和未定义行为检查。只使用普通本地 socket 与 `/dev/null`，不调用真实磁盘 ioctl。

实际前台路径首先普通只读打开；仅遇访问拒绝时使用 macOS 标准 `/usr/libexec/authopen -stdoutpipe -o`。系统授权由用户在系统窗口处理，取消时返回未弹出，不索取密码。标准工具在本机对 O_NOFOLLOW 返回 EINVAL，因此普通打开保留 O_NOFOLLOW，授权路径先 lstat 拒绝符号链接，authopen 只传 O_RDONLY 与 O_CLOEXEC；返回后核对字符设备节点，前台共享弹出实现再核验原介质身份及精确主次设备号。

无设备实测还验证了真实 authopen 对 `/dev/null` 的句柄传输与生产 C 接收器协作。该结果只证明调用协议正确，不能替代真实外接盘的系统授权、用户取消与最终弹出验收。

涉及 DiskService 的独立 swiftc 测试须包含 AuthorizedDeviceHandle.swift 和 App-Bridging-Header.h。若一个测试同时编译助手和应用源，应使用测试专用组合桥头包含 App-Bridging-Header.h 与 Helper-Bridging-Header.h，不能重复传两个互相覆盖的 -import-objc-header。

共享组件及固定盘回执修正后的纯回归为 167 项，前台授权边界为 53 项；原挂载状态、卸载序列、助手策略、普通文件 ACL 和会话恢复合计另有 94 项。最终前台 ioctl 路径已用新构建重新执行上述 5 项系统验收；旧后台路径的记录作为历史证据保留。操作排队提交后不承诺随时取消；句柄保持至明确结果，失败不宣称已弹出。

固定外部硬盘的 DKIOCEJECT 成功后可能保持 IOMedia 对象。生产流程先关闭原始设备描述符，再核对：可移除介质和镜像仍要求原对象消失；只有原始及当前属性均明确为外部、不可机械弹出、不可移除，原双介质身份及容量一致，同盘无挂载且所有同盘 IOMedia 的 Open 均明确为 false，才返回“已安全推出但仍连接”回执。属性未知、仍有挂载/打开引用或无成功回执均不算完成。

新增 29 项回归覆盖上述固定盘属性和全部关闭门禁、无回执/错误身份/容量变化/重新挂载拒绝，以及本会话成功实例的入口抑制。其他应用重新挂载会撤销安全提示与抑制；新插入的不同介质身份不受旧缓存影响。这些策略测试不代替真实固定硬盘的系统验收。

本轮最终系统重测证据为 `build/eject-0.1.1/系统验收-CB543140-D2CE-4FF3-9BCA-C2F82834CA7A/结果.json`；结果 5 项通过、错误为空，两份镜像的原介质与 hdiutil 映射均已消失。314 项无设备回归汇总为 `build/core-tests/最终固定盘回执回归结果.json`。这些本机报告不包含在公开源包中，公开测试入口可按条件复现。
