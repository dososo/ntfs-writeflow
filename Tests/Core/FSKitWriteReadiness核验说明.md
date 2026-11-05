# 旧 FSKit 内部准备协议与应用状态核验

这是私有候选中的共享协议及应用状态改动，未回写正式源码、未提交、未签名、未发版，也未操作虚拟机或真实磁盘。

## 1. 可检查行为

- 仅 macOS 15.4 及以上、26 以前的 FSKit 读写请求需要内部准备证明；原生只读、macFUSE 与 26 及以上不受此门禁影响。
- 固定选项 `writeflow-ready-token=`，准备属性 `com.blteam.ntfsworkbench.write-prepare.`，被动属性 `com.blteam.ntfsworkbench.write-ready.`；尾部只能是规范大写 UUID。
- 回执最多 1024 字节，仅允许 `schema:1`、`token`、正 `UInt64 mediaID`、`writable:true` 四字段。额外/重复/转义字段名、浮点或布尔冒充整数、错误 token／介质、超长和无效 JSON 均不能证明就绪。
- 内核读写标志保持原值。旧系统专用 root blntfs 挂载没有内部证明时显示“写入未就绪”，不显示绿色“可读写”；正常卸载资格不因此消失。
- 刷新只使用本次被动查询结果；等待查询后重新读取受影响设备的当前实例，再精确匹配当前介质、整盘、FSID、票据、路径、来源及后端。缺字段、显式 false、查询失败、矛盾或重复证明均不沿用以前的 true。等待期间同一介质卸载重挂为新 token／FSID 时，迟到证明不能贴回旧记录；消失或读取失败撤掉旧记录并增加清单未完整计数，bindings按新清单裁剪。
- 整体快照只发一次按需被动查询；查询预算 2 秒，其他 XPC 操作仍使用原 90 秒预算。应用成功挂载的旧 RW 分支必须收到 `writeReady:true`。

## 2. 文件与组件

| 行为 | 实现 |
| --- | --- |
| 系统范围 | `StorageBackend.requiresWriteReadiness(on:)`，共享协议的 `requires(backend:readOnly:on:)` 复用它 |
| 固定名称、选项及有限 JSON | `Sources/HelperShared/FSKitWriteReadiness.swift` |
| 可选结果字段 | `PrivilegedMountResult.writeReady`，旧结果缺字段解码为 nil |
| 系统标志与内部准备分开 | `VolumeRecord.needsWriteReadiness`、`access`、`writeReady`，`MountedFileSystem.managedToken` |
| 精确匹配及无缓存刷新 | `DiskService.recheckingWriteReadiness`、`applyingWriteReadiness`、`snapshot`、`record`，RPC后由`rawRecord`重新取得系统事实 |
| 短被动查询预算 | `PrivilegedMountClient.mountedVolumes` 专用 `call(timeout:2)` |
| 显示与卸载 | `VolumeDetailView` 新橙色状态及说明，`ContentView` 在未就绪时把历史操作明确标为“上次操作”并改为橙色提示，保留卸载等操作的反馈；卸载能力判断不变 |

管理员进程、私有子模式与扩展侧由其他执行者并行实现，本次没有编辑这些文件。被动查询是否完全不触发准备，以及扩展是否真的执行同步能力检查，必须由对应实现和实际系统验证，不能由本应用状态测试代替。

## 3. 已执行的命令和结果

```sh
bash Tests/Core/run_write_readiness_tests.sh
```

该脚本覆盖 ARM 原生及 x86_64 经 Rosetta，最低编译目标为 macOS 13、Swift 6，警告按错误处理；编译应用与所有界面，运行新协议／状态测试及原有卷记录、弹出和挂载状态回归。测试仅构造内存记录、隔离的默认值域及真实 AppModel，不枚举设备、不连接 XPC、不请求挂载。

已先得到缺协议／状态 API 的失败编译，再实现并通过回归。新增协议与状态测试每架构 81 项；原有卷记录 32 项、弹出策略 58 项、挂载状态 23 项均通过，完整应用和界面双架构严格类型检查通过。

独立审查随后发现“先读取 A、等待查询、迟到证明再贴旧 A”的陈旧实例问题。已先用可挂起 RPC 的内存 actor 复现旧实现失败，再改为 RPC 后重新读取实例。`FSKitReadinessRefreshTests.swift` 两架构各 12 项通过，覆盖同 media 更换 token／FSID、消失、重读失败、RPC失败及原实例不变。snapshot和record共用被测试的专用重核步骤。最终完整复跑同时覆盖81+12+32+58+23项及应用/界面严格类型检查。

私有最终日志为 `build/readiness-tests/异步重核双架构回归.log`。红例保存在 `build/readiness-tests/陈旧实例红例.log`，退出码1；修正前的早期80／81项日志继续保留，不混称最终一轮。

## 4. 推断与需要人工确认

协议中的 `writable:true` 必须来自扩展同锁完成真实准备后的结果，而不是重复内核可写标志。应用只验证协议和身份关联，不凭该字段证明介质后续写入永远成功。共享协议只固定契约，不实现或模拟资源授权、预检、同步或设备写入。

XPC 的 2 秒为超时调度预算；本次没有启动真实或延迟回复的 XPC 服务验证实际墙钟时延。其他磁盘枚举命令沿用原有逻辑，本轮没有改写其等待机制。

## 5. 尚未覆盖

未在 15.4 客体实际启动新候选、操作新窗口、验证权限提示、收到真实根 xattr 回执、测试失联助手、运行正常 VFS 写入或卸载。没有 Intel 实机和旧系统实体机证据。Rosetta、模拟系统版本、内存 AppModel 与严格编译不能替代这些验收。

需要整合方实际验证：准备失败后刷新和重启应用不变绿色；资源同步失败零 RW 创建／零写回且仍可只读；准备子进程超时持锁；被动查询不触发准备；同盘事务及旧票据恢复；真正读写、同步、正常卸载和离线摘要。

## 6. 最小回滚

本轮仅私有候选，无已发布产品回滚动作。停止使用该候选即可。若按源码撤回，需一起撤回本次共享协议、结果字段、应用映射与界面相关改动，并同步撤回并行助手／扩展对新协议的依赖，不能只删除共享文件导致编译缺失。不要覆盖其他执行者的改动。
