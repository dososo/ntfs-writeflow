# 系统授权挂载助手候选

本目录是由 `SMAppService.daemon` 承载的管理员服务。既有挂载与正常卸载已完成本机系统授权和真实介质验证；整盘弹出采用管理员服务正常卸载、前台授权同一设备描述符推出的两阶段流程，已在外部固定 USB 硬盘和新建镜像上验证，实际范围见版本说明。系统授权必须由主应用展示用途并经用户批准。

## 接口与文件边界

共享协议位于 `Sources/HelperShared/*.swift`。服务名、后台服务属性列表名、固定签名要求及根命名空间均由该文件定义。请求只包含设备标识、两层介质登记标识、介质容量和只读选择；不接受用户路径、任意命令、挂载选项或调用用户标识。用户标识取自已连接的 `NSXPCConnection.effectiveUserIdentifier`。

- `PrivilegedHelperMain.swift`：系统权限检查、固定名称监听器及运行循环。
- `PrivilegedMountService.swift`：连接签名要求、按连接隔离用户、串行执行固定挂载、卸载、整盘弹出前准备与恢复查询。
- `HelperMedia.swift`：固定 `diskutil info` 查询、外部 NTFS 条件、保留介质对象与两层登记标识复核。
- `HelperNamespace.swift`：由系统拥有的目录、命名用户只读遍历 ACL、持久化挂载凭据、正常卸载后的单文件与空目录清理。
- `HelperEject.swift`：独立核对原介质与挂载根句柄数组，完成同步及正常卸载；不执行原始设备弹出。
- `Helper-Bridging-Header.h`：引入系统公开的成员身份和共享磁盘控制定义；最终 `DKIOCEJECT` 调用只在前台应用进程发生。

助手还编译现有 `Sources/Core/VolumeRecord.swift` 和 `Sources/App/Services/MountedFileSystemReader.swift`；不依赖应用的 `DiskService`。

## 访问与介质保护

监听器在恢复连接前调用系统公开 `setCodeSigningRequirement`，限定 Apple 信任链、团队 `ALV8Y54GCY` 与应用标识 `com.blteam.ntfsworkbench`。系统按消息验证签名，不通过查询可能复用的进程编号推断身份。客户端同样应在连接恢复前设置共享配置提供的助手签名要求。

挂载前核验 `diskutil` 报告的外部 NTFS、稳定介质容量、未挂载状态及可写性，并持有磁盘仲裁和 IOKit 对象核对介质登记标识。保留介质的父链必须报告明确外接位置，或文件镜像的虚拟接口；内部和不能明确分类的介质不放行。挂载使用固定 `/sbin/mount -F -t blntfs`，只追加固定安全选项和已核验的介质标识。仅该挂载子进程的干净环境带 `SUDO_UID=可信连接用户标识`；环境仍只含固定 `PATH`、`LANG` 和该值，磁盘查询不接收它。协议不允许用户提供 UID、环境、命令、额外选项或路径。[Apple 的挂载实现](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m#L48-L67) 显式处理这一变量：在真实 UID 为 root 时，由挂载程序自身调整真实 UID，以用户身份发现扩展，同时保留有效 root 身份访问设备。助手本身不改凭据，不调用私有接口或添加 fork 包装。此前只切换 bootstrap 和审计会话的 `asuser` 方案未解决实机扩展发现，已移除。扩展仍必须在打开资源、允许写入前校验 `writeflow-media-id`；助手不能替代这道防止设备编号复用的门禁。

根命名空间为 `/private/var/db/com.blteam.ntfsworkbench.mounts`。选择系统数据目录是因为本机系统运行目录带组写权限，不满足不可替换的父目录要求；权限检查保持严格。实际路径仅由连接用户标识、随机 UUID 凭据和固定 `volume` 子目录拼成。所有目录由系统拥有；用户目录仅给对应用户列目录、搜索和读取属性的 ACL，不授予写入、删除、换所有者或修改权限。每一级目录通过描述符拒绝符号链接并核验权限；已有不符合要求的目录不会被修补后使用。新目录先在 `umask 077` 下建立，再对该新目录设置预期模式与 ACL。

每个凭据目录保存系统所有、模式 `0600` 的 JSON 凭据。应用或守护进程重启后可以通过 `mountedVolumes` 恢复，或从严格命名空间路径提取 UUID 后请求卸载。系统重启后挂载已经结束，数据目录中的凭据可能仍保留；查询先确认实际挂载存在，再读取凭据，因此创建目录后、凭据落盘前退出留下的孤目录不会阻断恢复查询。不自动重新挂载，也不批量清理。实际挂载存在时，凭据缺失或不符合要求仍报告错误。恢复与卸载仍重新核验介质标识、挂载类型、来源设备、系统所有权和文件系统实例标识。凭据落盘前挂载已经成功的进程退出窗口，只有完整复核后才补记实例标识。

挂载返回成功必须符合请求访问模式。如果系统将读写请求降级为只读，助手报告未达到请求，并保留凭据；查询报告实际只读状态，同一用户仍可以正常卸载。不得因访问模式不符而放弃回收失败挂载。

卸载接收凭据 UUID 和应用通过 NSXPC 传来的 `NSFileHandle`。应用先在用户上下文打开已核验根目录的 `O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 句柄，并再次 `fstatfs` 核对；原句柄由应用持有到回复或错误返回后关闭。助手保持凭据、连接用户、介质及实际挂载核验，再检查传入描述符是目录、带事件标志、`F_GETPATH` 等于精确挂载根路径且 `fstatfs` 完全匹配，然后执行 `fsync` 和 `funmount(fd, 0)`。接收的独立描述符由助手队列强持有到操作结束后关闭；助手不自行打开受保护卷。事件描述符避免目录读引用使自身卸载返回占用，同卷子目录也不能冒充根目录。同步或卸载失败均报告错误，不使用强制卸载，不按用户路径执行卸载，不提供修复或格式化。整盘弹出通过下面独立受限协议处理。

## 整盘弹出的前台授权与描述符边界

管理员服务协议仅提供 `prepareEject(request, handles)` 进行准备，最终弹出由应用进程调用共享 `HelperEject.eject` 完成。请求含源卷及整盘设备名、两层 IOMedia 登记标识和稳定容量，不接受任意路径、命令或用户身份参数。前台先正常卸载本应用管理的同盘卷，再为其他同盘挂载打开事件根句柄。准备阶段从 IOMedia 树和内核挂载表重新建立同盘清单，拒绝残留 `blntfs`、内部设备、非 `/Volumes` 挂载或其他用户的挂载；逐项验证句柄是唯一原挂载根、带 `O_EVTONLY`，来源、路径、实例和所有者完全一致。全部句柄先通过检查，才逐卷同步并执行 `funmount(fd, 0)`。最后确认同盘没有挂载，并在回复前关闭接收端的各个根句柄。

前台收到准备完成后关闭自己持有的根句柄，再普通只读打开精确的 `/dev/rdiskN`。只在遇到访问拒绝时调用系统 `/usr/libexec/authopen -stdoutpipe` 申请只读设备描述符。系统可能显示 macOS 管理员认证窗口，必须由用户本人完成；取消时停止后续弹出，并明确提示分卷可能已卸载。普通打开使用 `O_NOFOLLOW`；授权路径先以 `lstat` 拒绝符号链接，随后核对返回字符设备节点号。任何方式都不使用会截断文件的写入选项，不修改设备权限或增加后台完全磁盘访问权限。

最终设备操作在前台应用进程的后台队列执行，不通过 XPC 交给守护进程。先独立重建并核对原 IOMedia 登记标识、设备名、稳定容量和外部协议。`F_GETFL` 必须为只读且不是事件描述符；`fstat` 必须为字符设备且主次设备号与原整盘一致。授权期间发生重插或替换，即使 BSD 名相同也拒绝。仅当同盘仍无挂载，才对这个持续持有的描述符执行 `DKIOCEJECT`。只有占用错误按每次 100 毫秒、最多 3 秒重试；每次重复身份、句柄与空挂载检查，不关闭重开，不强制弹出。

内核请求成功后关闭原始设备句柄，再确认后置状态。镜像或可移除介质要求原对象离线；对原始及当前属性均明确为 `External`、`Ejectable=false`、`Removable=false` 的固定硬盘，允许保留物理连接，但原两层介质身份及容量必须一致，同盘无挂载，整个同盘 IOMedia 树的 `Open` 都明确为 `false`，才返回固定盘成功回执。属性缺失、仍有挂载或打开引用、没有成功回执都不算完成。`AppModel` 再通过 `EjectVerification` 回读核验，刷新发现其他程序重新挂载时撤销本会话已推出标记。

原始设备打开期间不运行可能重新探测设备内容的 `diskutil`；最终阶段只使用 DA 已知描述、保留 IOMedia 属性、`fstat` 和内核挂载表。设备描述符用于绑定设备实例，不用于读取用户文件。先完成卸载并关闭根句柄，再打开原始设备，避免设备探测与自身打开引用造成占用。

实现依据：[Apple DiskArbitration 卸载与弹出](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DARequest.c)、[XNU 特殊设备关闭语义](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/specfs/spec_vnops.c)、[IOStorage 的设备引用和弹出检查](https://github.com/apple-oss-distributions/IOStorageFamily/blob/main/IOMediaBSDClient.cpp)。系统 `authopen(1)` 手册说明精确路径只读授权及 `SCM_RIGHTS` 描述符传递。开源实现审查不能代替当前系统的真实介质验收。

## 已执行的候选验证

从仓库根目录编译候选，生成后不要直接运行或据此推断服务已注册：

```sh
mkdir -p build/helper-candidate
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Sources/HelperShared/*.swift Sources/PrivilegedHelper/*.swift \
  -o build/helper-candidate/NTFSWriteFlowMountHelper
```

策略测试编译及执行命令：

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Sources/HelperShared/*.swift \
  Sources/PrivilegedHelper/HelperMedia.swift \
  Sources/PrivilegedHelper/HelperNamespace.swift \
  Sources/PrivilegedHelper/HelperEject.swift \
  Sources/PrivilegedHelper/PrivilegedMountService.swift \
  Tests/Core/PrivilegedHelperPolicyTests.swift \
  -o build/helper-candidate/助手策略验证
build/helper-candidate/助手策略验证
```

候选完整编译通过，策略测试 39 项通过：原有 38 项覆盖路径和用户隔离、签名要求的系统解析及临时测试进程拒绝、协议接口创建、过大或无效设备请求在查询前拒绝、内存 ACL 的有效性与最小权限、访问模式降级可回收且不能放松所有者及挂载实例核验；新增一项拒绝旧运行目录中的候选路径。测试不建立监听连接、不设置文件 ACL、不执行设备查询或挂载。

后续真实服务进入助手时暴露 ACL 接口类型问题：`acl_get_fd` 读取的是访问 ACL，必须显式使用 `acl_get_fd_np(fd, ACL_TYPE_EXTENDED)`。设置也统一使用显式扩展类型。APFS 对不存在的扩展 ACL 返回 `ENOENT`；只有预期空 ACL，且 `fstatx_np` 成功并由 `filesec_query_property` 明确确认 ACL 属性不存在时才接受，其余错误仍拒绝。

新增 `Tests/Core/PrivilegedHelperACLTests.swift` 在本次新建的普通目录和文件上真实设置及读取扩展 ACL，11 项通过：空 ACL、命名用户 ACL、缺少必需命名授权拒绝、额外授权及写权限拒绝、无效描述符读取失败拒绝。测试文件与空目录已逐个正常清理，不改变系统目录，也不查询或操作设备。此结果不等于跨用户访问实测。证据为 `build/helper-candidate/扩展ACL验证结果.json`。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Sources/HelperShared/*.swift \
  Sources/PrivilegedHelper/HelperMedia.swift \
  Sources/PrivilegedHelper/HelperNamespace.swift \
  Sources/PrivilegedHelper/HelperEject.swift \
  Sources/PrivilegedHelper/PrivilegedMountService.swift \
  Tests/Core/PrivilegedHelperACLTests.swift \
  -o build/helper-candidate/助手扩展ACL验证
build/helper-candidate/助手扩展ACL验证
```

## 既有权限与句柄验证

真实匿名 NSXPC 句柄传输测试 13 项通过：`NSFileHandle` 的事件描述符能通过协议传递，异步接收端持有并关闭自己的副本后发送端仍有效；无效句柄、普通文件、非根目录、非事件句柄和不同文件系统实例均拒绝。测试只读取已有根文件系统元数据并建立临时普通文件，不调用生产挂载、同步或卸载，不注册后台服务。临时文件与空目录已正常清理。结果为 `build/helper-candidate/句柄传输验证结果.json`；这不能替代实际已签名应用到 root 服务的 TCC 与卸载验证。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Sources/HelperShared/*.swift \
  Sources/PrivilegedHelper/HelperMedia.swift \
  Sources/PrivilegedHelper/HelperNamespace.swift \
  Sources/PrivilegedHelper/HelperEject.swift \
  Sources/PrivilegedHelper/PrivilegedMountService.swift \
  Tests/Core/PrivilegedHelperHandleTests.swift \
  -o build/helper-candidate/助手句柄传输验证
build/helper-candidate/助手句柄传输验证
```

会话调用与恢复顺序 18 项回归通过：固定程序和选项、可信用户标识校验、仅挂载子进程的固定环境、其他程序及无效用户不能接收挂载身份、助手派生路径、新建无票据空目录跳过，以及实际挂载存在时凭据错误仍传播。测试只构造命令与环境，不运行挂载命令；空目录已正常清理。完整助手编译通过，结果为 `build/helper-candidate/会话与恢复验证结果.json`。

```sh
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Sources/HelperShared/*.swift \
  Sources/PrivilegedHelper/HelperMedia.swift \
  Sources/PrivilegedHelper/HelperNamespace.swift \
  Sources/PrivilegedHelper/HelperEject.swift \
  Sources/PrivilegedHelper/PrivilegedMountService.swift \
  Tests/Core/PrivilegedHelperSessionTests.swift \
  -o build/helper-candidate/助手会话恢复验证
build/helper-candidate/助手会话恢复验证
```

必须实际验证后台服务注册与批准、真实签名客户端允许及错误签名拒绝、目录 ACL 在系统文件上的效果、多用户隔离、后台进程重启恢复、资源占用与同步错误、只读及读写挂载回读。既有真实盘挂载已证实固定会话调用能够发现当前用户启用的扩展，但其他机器仍需验证。固定 `noowners` 选项用于让应用用户访问扩展返回的系统所有文件；其行为和 Finder 访问同样需要实际验证。

当前没有增加磁盘仲裁独占声明；并发驱动占用由系统挂载及 FSKit 资源机制处理，仍需冲突场景验收。此候选的编译与策略通过不能代替真实盘读写、安全故障注入或发布验收。撤回候选可先停止应用调用、正常卸载已有卷，再经应用的正式后台服务注销流程处理；本目录不包含绕过系统批准的安装或卸载命令。

## 0.1.1 验收范围

当前共有 314 项非设备回归通过，详细构成与执行命令见 `Tests/Core/README.md`。外部固定 USB 硬盘通过正式应用的正常卸载和前台安全推出，随后独立核对原介质登记身份、无挂载和全树打开状态关闭。专用新建镜像通过 GUI 读写挂载和整盘弹出，原设备及镜像映射消失，65,573 字节测试文件经离线工具复读摘要一致。镜像与固定硬盘使用各自后置判定，没有把固定盘仍登记误报为失败，也没有把仅卸载误报为可断开。


当前系统弹出集成另有 5 项真实镜像用例通过：错误介质身份拒绝；打开普通文件时拒绝并保留介质；关闭文件后正常弹出；额外原始设备句柄占用时约 3 秒有界拒绝；关闭该句柄后弹出未挂载整盘。两份新建镜像均正常释放。多分区物理盘、真实热拔插与断电不在这 5 项覆盖范围内。

硬件异常拔插、掉电、多分区物理盘、多用户实际切换、Windows 交叉验证及长期稳定性仍未覆盖。该版本二进制的签名、公证、装订和解包后 Gatekeeper 结果见随包分发验证摘要，不由源码构建成功推断。
