# 旧FSKit内部准备与准确状态核验

0.3.1（构建8）源码已整合提交为[2347927](https://github.com/dososo/ntfs-writeflow/commit/23479279258f1887eada9c6d6b676d9583d92c05)。范围包含共享协议、管理员探针与恢复查询、FSKit适配层、C状态接口和应用状态，已不是单独执行者的私有交接。阶段四同版本通用Release构建、正式签名与`codesign --verify --strict`通过，未公证、未做新候选VM验收、未发布，没有构建8真实客体或完整VFS通过结论。第一份构建8因预检收尾P1阻断保留不可用，不混作当前阶段四候选。

## 一、可检查行为

- 只有15.4及以上、26以前的受管FSKit读写需要内部证明；原生RO、macFUSE和26及以上不走该握手。
- 选项`writeflow-ready-token=`、准备属性`com.blteam.ntfsworkbench.write-prepare.`、状态属性`com.blteam.ntfsworkbench.write-ready.`尾部只能是规范大写UUID。回执最多1024字节、仅`schema:1`／`token`／正`UInt64 mediaID`／`writable:true`四字段，错误类型、额外／重复键及错误绑定拒绝。
- load／activate合并nonce与media许可；带绑定的旧RW在握手前拒绝后台修改。原资源能力拒绝及原RO仍存活阶段的只读预检／身份拒绝保RO并锁存错误；新包装器准备后才消费RO并开启RW，未转移时精确清理。
- prepare只认精确根项和nonce；status只读内部状态、不触发准备、不调用sync或清错。盘上同名属性不能冒充回执，保留前缀的设置／删除拒绝，列表隐藏。
- 助手从票据专用验签root副本执行固定私有模式，通过stdin继承根FD，在租约及前后票据／FSID／介质核验下取回执。超时不是取消，未完成探针仍受租约保护。
- 内核只读位不伪造；旧专用blntfs内核RW而无有效内部证明时显示“写入未就绪”，保留卸载入口。恢复只查询status，应用被动查询预算2秒、其他XPC原90秒不变。
- RPC后重新读取受影响设备当前实例，再匹配介质／整盘／FSID／token／路径／来源／后端。等待间同media重挂不能套旧证明；消失或读取失败撤旧行计unreadable，bindings按新记录裁剪，不缓存true。

## 二、文件与函数

| 行为 | 实现 |
| --- | --- |
| 范围与有限协议 | `StorageBackend.requiresWriteReadiness`、`FSKitWriteReadiness`、`PrivilegedMountResult.writeReady` |
| 原资源检查／根属性 | `ntfs3gFileSystem.loadResource`、`ntfs3gVolume.prepareMountLocked`／`preparationReceiptLocked`／`writableHandleLocked` |
| 无IO错误状态 | C桥`nfsk_write_status`，仅读RO及已锁存写回错误 |
| 固定根FD探针 | `FSKitWriteProbe.execute`、`PrivilegedHelperMain`内部分派、`HelperCommand.runBridge(input:)`、`LegacyRuntime.verifyCurrentMountHelper`和`UnmountLease` |
| 首次与恢复 | `PrivilegedMountEngine.mount`先prepare，`mountedVolumes`只status；内核访问标志与`writeReady`分开返回 |
| 异步状态重核 | `DiskService.recheckingWriteReadiness`／`applyingWriteReadiness`，`snapshot`／`record`共用，RPC后`rawRecord`重读 |
| 准确显示 | `VolumeRecord.access`及详情橙色状态；历史操作在未就绪时标明“上次操作”，不保留绿色成功提示 |

## 三、已执行命令与证据边界

在对应源码和已有双架构引擎环境执行：

```sh
bash Tests/Core/run_write_readiness_tests.sh
bash Tests/Engine/run_write_capability.sh
bash Tests/Engine/run_write_ready.sh
NTFS_TEST_ARCH=arm64 bash Tests/Core/run_eject_tests.sh
NTFS_TEST_ARCH=x86_64 bash Tests/Core/run_eject_tests.sh
```

协议／应用状态81项及可挂起RPC实例重读12项，连同原32＋58＋23项，两架构通过；全应用／界面最低macOS13、Swift6警告按错误检查通过。实例重读反例先使旧实现退出1，再验证A→B、消失、重读失败、RPC失败和实例不变；真实AppModel收到新快照后撤销旧绿色，重建模型无缓存true。

助手完整核心两架构通过，其中18项覆盖固定私有参数、CLOEXEC原FD经stdin继承、父侧FD仍有效和有界未知结果。适配层／真实普通镜像验证能力失败零RW创建／零数据写回、RO读取与清理、nonce拒绝磁盘伪造及被动状态不清错；不是目标FSBlock或root实际挂载验证。阶段四`run_write_ready.sh`、`run_write_capability.sh`、`run_mount_options.sh`三runner双架构及六目标检查全0，并完成独立只读审查。历史红例和各阶段原始日志保留，不以新的开发通过改写旧客体失败。

## 四、推断与需要人工确认

回执必须来自扩展完成真实内部准备，不能只重复内核RW。资源公开flush返回成功不证明后续每一次写入永远成功；2秒为客户端调度预算，尚未用真实延迟XPC验证墙钟时延。RO保留后系统notReady状态是否仍允许真实读取和正常卸载，也须客体验收。

## 五、收尾P1修复与未覆盖

**阶段四2347927已修复并独立审查：** 原先7535d05的预检拒绝空handle／sync ENXIO问题，改为仅旧分支在原RO存活时完成只读预检、身份与包装器准备；失败锁存保RO，成功后才关闭并转移。三个runner双架构及六目标检查全0，新增测试实际先sync再unmount／deactivate；原RO关闭失败精确清理未转移包装器，RW开始后的sync／sticky／close错误仍拒绝。保RO不扩大到这些真实IO错误，空handle同步仍ENXIO。

构建8尚未在15.4实际验证root根FD／xattr、失联助手、超时租约、真实准备／状态、正常VFS读写／同步／忙句柄／卸载／重挂。没有Intel实体机或旧系统实体机结论。Rosetta、模拟系统版本、内存模型与严格编译不能代替这些验收；f9和IOKit实验的EIO／卸载失败保留。

## 六、最小回滚

没有已发布构建8安装包需要撤回。可停止制品提升；若回滚源码，应将共享协议、助手、适配层、C状态接口和应用状态作为依赖整体撤回并重建，不能只删除共享文件或放宽门禁。失败或未知时保留诊断、票据、锁及回执，不删除现场或强制卸载来继续。
