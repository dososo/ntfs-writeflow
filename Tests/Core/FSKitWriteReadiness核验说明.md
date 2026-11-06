# 旧FSKit内部准备与准确状态核验

当前为[0.3.1（构建10）源码206af70](https://github.com/dososo/ntfs-writeflow/commit/206af70bb138252bb090064252a47a8ff2bfec69)，尚未发布。222019a根缓存候选收尾47项／架构、原四runner双架构及六目标0、独审已通过；构建10在15.4受控镜像同包完整链已通过，下载仍为0.3.0。 构建9真实VFS步骤完成但deactivate16，完整失败；重启登记／交互中断另列，不把旧公证沿用于10。本轮发行基于206af70的475项冻结输入；App与DMG分别公证通过，21文件摘要／大小／权限一致，严格签名、Gatekeeper和stapler检查均退出0。构建10在macOS15.4（24E248）ARM客体的受控镜像完整链及内部sync0／close0／RO重开0已核验通过；本机实盘及最终源码分发仍待验。

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
NTFS_TEST_ENGINE_ROOT="$PWD/build/engine" bash Tests/Engine/run_write_capability.sh
NTFS_TEST_ENGINE_ROOT="$PWD/build/engine" bash Tests/Engine/run_write_ready.sh
NTFS_TEST_ARCH=arm64 bash Tests/Core/run_eject_tests.sh
NTFS_TEST_ARCH=x86_64 bash Tests/Core/run_eject_tests.sh
```

协议／应用状态81项及可挂起RPC实例重读12项，连同原32＋58＋23项，两架构通过；全应用／界面最低macOS13、Swift6警告按错误检查通过。实例重读反例先使旧实现退出1，再验证A→B、消失、重读失败、RPC失败和实例不变；真实AppModel收到新快照后撤销旧绿色，重建模型无缓存true。

助手完整核心两架构通过，其中18项覆盖固定私有参数、CLOEXEC原FD经stdin继承、父侧FD仍有效和有界未知结果。适配层／真实普通镜像验证能力失败零RW创建／零数据写回、RO读取与清理、nonce拒绝磁盘伪造及被动状态不清错；不是目标FSBlock或root实际挂载验证。阶段四`run_write_ready.sh`、`run_write_capability.sh`、`run_mount_options.sh`三runner双架构及六目标检查全0，并完成独立只读审查。历史红例和各阶段原始日志保留，不以新的开发通过改写旧客体失败。

## 四、推断与需要人工确认

回执必须来自扩展完成真实内部准备，不能只重复内核RW。资源公开flush返回成功不证明后续每一次写入永远成功；2秒为客户端调度预算，尚未用真实延迟XPC验证墙钟时延。阶段四构建8已真实负向观察notReady后根可读及正常清理；不能外推构建9正向写入、所有失败或所有系统。

## 五、收尾P1修复与未覆盖

**阶段四2347927已修复并独立审查：** 原先7535d05的预检拒绝空handle／sync ENXIO问题，改为仅旧分支在原RO存活时完成只读预检、身份与包装器准备；失败锁存保RO，成功后才关闭并转移。三个runner双架构及六目标检查全0，新增测试实际先sync再unmount／deactivate；原RO关闭失败精确清理未转移包装器，RW开始后的sync／sticky／close错误仍拒绝。保RO不扩大到这些真实IO错误，空handle同步仍ENXIO。

阶段四构建8已有实际根prepare到flush EIO、刷新／重启后未就绪、正常GUI卸载和分离、最终镜像与模板摘要相同的负向证据，原结果false不变。构建9旧子类和收尾组合五runner／六目标全0；新增停用33项两架构覆盖真实C活动open／force拒绝、sync／close首错锁存、RO同实例再激活和再次RW，现代noIO不变。

**构建10本次同包已过：** 新根缓存仅在旧deactivate排除FILE_root，通用C查询不改，非根busy和force仍拒；47项两架构、四runner两架构和六目标0。15.4本次受控镜像正向准备、写读／同步、busy拒绝、RO重挂与正常分离通过；同模块全部打开1／非根0，明确sync0／close0／RO重开0。不据此追认构建9当时根因，也不证明收尾失败能传回App；公开有效位与现代系统路径边界仍保留。

现代系统本轮改用本机macOS26.6.2与已授权5TB外部USB的一轮实际验收，文件写读／同步／占用拒绝／RO重挂结果尚待。不会额外启动26.4 VM；26.4仅处镜像准备，未启动、未通过。只读DA／IOMedia元数据验证不等于实盘文件操作成功。

## 六、最小回滚

没有已发布0.3.1安装包需要撤回。可停止制品提升；若回滚源码，应将共享协议、助手、适配层、C状态接口和应用状态作为依赖整体撤回并重建，不能只删除共享文件或放宽门禁。失败或未知时保留诊断、票据、锁及回执，不删除现场或强制卸载来继续。
