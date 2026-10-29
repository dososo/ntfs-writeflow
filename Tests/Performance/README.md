# 受保护的逐步性能实验

本工具实现固定计划、全部负载执行器、持久累计预算和分组报告；驱动切换由实验人员单独操作，工具不会切换、卸载、格式化、修复或批量清理。当前通过的是本机内盘小负载构造边界，以及直接用户和管理员root两种真实blntfs镜像隔离与4MiB内部执行器验证；不能作为真实外置NTFS或Paragon性能结论。

## 复用与准备

使用官方fio固定提交 `f8127399732876749f4855fb35ac3b8693fc7463`（GPL v2）的psync、SHA256验证和JSON输出。工具不把fio嵌入应用，不全局安装，构建产物留在build。分发fio二进制时须提供对应源码与许可。`direct=1`在macOS请求F_NOCACHE，不表示冷缓存；同步、摘要或重挂复读均不能代替掉电安全验收。

在仓库根目录编译只读查询工具：

```sh
mkdir -p build/performance
xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 \
  -import-objc-header Tests/Performance/Benchmark-Bridging-Header.h \
  Sources/HelperShared/PrivilegedMountProtocol.swift Sources/PrivilegedHelper/HelperNamespace.swift \
  Sources/Core/VolumeRecord.swift Sources/App/Services/MountedFileSystemReader.swift \
  Tests/Performance/IsolationProbe.swift Tests/Performance/TargetProbe.swift -framework IOKit -o build/performance/target-probe
```

fio在独立build目录以固定提交configure/make，运行时显式指定二进制及本机清单；清单JSON含 `commit` 与 `binary_sha256`，逐次核对实际二进制。此清单、本机路径和测试数据不提交仓库。

## 计划与额度

```sh
python3 Tests/Performance/benchmark.py plan --output build/performance/plan.json
```

计划有两种缓存口径，每种口径ABBA三轮，每驱动、每负载六个样本；包含预演、预热、初始化和读写依赖。上限1008GiB，累计门限1024GiB，两种缓存口径分别限制512GiB（固定计划各约504GiB）。随机四进程合计1GiB，每进程使用独立文件。小文件/同步共享8GiB保守预留，实际写量另外记录；全部额度均为逻辑写量，不包含元数据和闪存写放大。

正式 `--step` 必须提供 `--ledger`。账本使用当前用户0600普通文件、无符号链接、独占锁，整个步骤持有锁；执行IO前先预留预算并fsync，失败/中断额度不退还。逐条预留、总数和每缓存口径预留必须一致，失败额度同时计入所属缓存口径，坏文件不重置。必须依计划顺序执行；已完成步骤不能重复充数，失败留在原步骤，预算不足即拒绝。账本只存依赖所需摘要，完整原始结果留在每步报告。

计划不是实盘压力授权。正式全套会长时间占用盘、保留大量新文件，须另行明确测试介质和范围。工具不提供清理功能。

## 执行与门禁

先用只读查询工具观察已获准的外部NTFS专用目录：

```sh
build/performance/target-probe "${TEST_DIRECTORY:?先设置已获准测试目录}"
```

探针从真实statfs读取提供方，IOKit读取当前介质ID和容量；diskutil只辅助判断内部/虚拟属性。执行器只接受外部物理、可写的 `blntfs` 或 `ufsd_NTFS`。内部盘、镜像、raw路径、符号链接、身份/容量不符全部拒绝。实际提供方不符报告 `waiting`，等待实验人员切换后使用新报告路径再运行；不会自动切驱动。

正式单步命令示例（占位变量必须来自本次只读探针；并非立即执行指令）：

```sh
python3 Tests/Performance/benchmark.py run \
  --target "${TEST_DIRECTORY:?}" --probe build/performance/target-probe \
  --fio "${FIO_BINARY:?}" --fio-manifest "${FIO_MANIFEST:?}" \
  --expect-provider blntfs --expect-media-id "${MEDIA_ID:?}" \
  --expect-capacity "${CAPACITY_BYTES:?}" \
  --step step-001 --ledger "${HOST_LEDGER_ABSOLUTE_PATH:?}" \
  --timeout 3600 --output "${NEW_HOST_REPORT_PATH:?}"
```

`--step`使用固定计划的大小、并发和额度；缓存必须匹配，第二口径加 `--direct`。每次保留20GiB和卷容量20%空间。默认无step的顺序写为4MiB，上限32GiB；可用 `--workload`、`--concurrency 1|4`、`--size-mib`、`--budget-mib`做获准的小负载单步。小文件默认256个、每个4KiB，正式计划10000个。无step的依赖读写必须显式 `--source-report` 指定前一步已通过报告；正式计划由账本找前置步骤。

只创建随机新目录和独占新文件。新目录须有当前用户0700隔离，或通过下述逐级FD/ACL外层隔离证明；源文件须为当前用户普通文件、单链接、完整摘要匹配。依赖只复用本工具所有权标记一致、介质/参数一致的工作集，不能把任意既有文件交给fio。每步持有目录FD；子进程exec前fchdir绑定已验证目录，禁止fio创建额外文件；前后核对挂载实例、介质和路径对应的目录inode。

**本轮真实blntfs镜像观察：请求目录0700后实际mode为777，uid被FSKit挂载层映射为当前用户501。** 因此新增等价外层隔离：只对blntfs逐级 `openat(O_NOFOLLOW)`，每级核验所有权/安全模式/空ACL；公开可写祖先须root拥有且有sticky位。卷外隔离祖先必须是真实独立APFS、当前UID拥有、0700且没有任何ACL。`getmntinfo`要求同source或fsid只有一条挂载，挂载根/卷内FD信息必须与真实statfs一致。Python持有该祖先FD，核对其dev/inode、查询目录FD和挂载身份；执行前后证明必须一致。纯词法拒绝`.`、`..`和重复分隔符，实际符号链接仍由逐级NOFOLLOW拒绝；不能用会改写/private/tmp别名的Foundation标准化代替FD检查。

另支持独立的`helper-root-acl`类型：实际挂载owner必须是root，挂载点必须由生产`PrivilegedMountConfiguration.token`解析为精确的`namespace/当前UID/大写UUID/volume`。安全root祖先及UUID层逐级核验，base/UUID层root755、用户层root700；用户层直接复用生产`HelperNamespace.verifyACL(fd, allowedUser:当前UID)`，只允许其既有只读遍历ACL，其他层复用生产空ACL检查。不新增ACL条目、不修改助手权限或卷内UID。Python分别核对隔离类型、调用UID、root挂载owner、精确namespace/UUID、祖先FD dev/inode/owner700，执行前后同一证明。root挂载不能借当前UID目录快路径绕过检查；普通私有目录快路径也必须由真实探针证明空ACL并绑定目录FD。

只认路径前缀、额外写ACL、错UID/UUID、可写祖先或缺少独立挂载证据全部拒绝。Paragon的同条件私有目录/挂载路径仍需实测。真实镜像隔离通过不等于物理介质性能已验收。

## 负载与内容验证

- 预演/预热/顺序写：psync、depth1、固定seed、1MiB块、完整fio SHA256验证、end_fsync。
- 顺序读：前置顺序写报告及全文件摘要必须一致，完整读并验证；不重新生成读数据。
- 随机初始化/写/读：4KiB块、固定seed、不重复随机映射；1或4个独立作业，合计工作集固定，随机读写分别依赖初始化/写结果，fio校验加全文件SHA256。
- 小文件/同步：独占新建、每文件fsync、读回、改名、枚举及逐文件完整SHA256；记录同步累计耗时。吞吐表示整条小文件操作流程的有效负载速率，不冒充纯写带宽。

fio和小文件步骤均由自有子进程执行并配置超时，超时保留现场、不自动重试。缓存请求不支持则失败；不静默改变缓存语义。报告保存实际提供方、身份、参数、seed、耗时、同步策略/统计、fio原始JSON和完整文件摘要。每个fio作业保留原始usr_cpu/sys_cpu；fio和小文件子步骤均用macOS官方`/usr/bin/time -l`记录user/sys CPU秒和最大常驻集字节。资源统计独立于吞吐分组，峰值RSS不是系统总内存或多个并发作业同时RSS之和。使用独立进程组，超时只终止本工具创建的整组进程，保留官方原始记录。失败或中断之后依赖摘要不符会拒绝继续，不尝试修复工作集。

## 只读跨驱动内容复核

`verify`只读取原成功报告绑定的本工具工作集。先由实验人员正常卸载、选择驱动并**只读重挂**，工具不代为切换；实际statfs不是只读则拒绝，避免RW挂载的atime更新破坏目标零写入语义。必须明确新挂载专用父目录、实际provider、本次mediaID和容量：

```sh
python3 Tests/Performance/benchmark.py verify \
  --source-report "${ORIGINAL_SUCCESS_REPORT:?原run成功报告}" \
  --target "${READ_ONLY_TEST_DIRECTORY:?新只读挂载的专用父目录}" \
  --probe build/performance/target-probe --expect-provider ufsd_NTFS \
  --expect-media-id "${MEDIA_ID:?}" --expect-capacity "${CAPACITY_BYTES:?}" \
  --output "${NEW_INTERNAL_APFS_REPORT:?内部APFS上的新绝对报告路径}"
```

原报告必须为当前用户、单链接、有界普通文件，且schema/status正确；其中session UUID、marker token、并发/数量及文件名白名单均严格校验。只认`workload.N.dat`或`checked-NNNNN.dat`对应的完整集合，拒绝绝对路径、`..`、链接、错token和任意用户既有文件。目标目录、marker和文件一律经只读FD/NOFOLLOW访问，逐文件核对实际regular/当前UID/单链接、长度和全量SHA256，保留全部不一致、缺失和错误；不因第一处坏文件丢掉后续结果。读取前后重核实际介质/挂载/只读状态、marker、文件身份及隔离祖先FD。

报告只允许写到FD绑定的内部可写APFS父目录，通过该父FD独占创建，拒绝输出到测试卷。验证函数不创建、修改、修复或删除卷内文件；仅以只读方式读取不等于掉电安全。源提供方与实际提供方不同才标`cross-provider`，相同只标`same-provider`；这两类正确性记录单独放入汇总的`content_verifications`，均不计吞吐样本。生产入口继续拒绝虚拟盘及fixture源报告；没有通用旁路参数。

本轮只在自建128MiB镜像上通过生产DiskService正常RW卸载、RO重挂验证同驱动逻辑，并比较整个镜像只读周期前后SHA256；没有据此宣称Paragon跨驱动或Windows实际结果。无参数入口和命令见[镜像验收说明](../System/性能隔离镜像说明.md)。

## 汇总、测试与边界

```sh
python3 -m unittest discover -s Tests/Performance -p 'test_*.py'
python3 Tests/Performance/benchmark.py report 结果一.json 结果二.json --output 新报告.json
```

显式设置 `WRITEFLOW_FIO_SMOKE` 为本机构建fio可加跑真实小负载：仅测试代码注入构造身份，不给生产入口增加内部盘开关。新建内盘目录及报告保留，不自动删除。结果写明构造边界，不能计入正式报告。

报告按负载、缓存、实际驱动和大小/并发/fio版本/seed/队列/同步参数分组，输出中位数、最小最大值、波动、同步时间和全部失败；超过10%波动提示调查，不筛慢样本。重复run_id/step、与固定计划不符的参数或超额写量不能计数。正式完整状态须所有步骤覆盖，每组六个不同计划样本，参数一致；缺样本、失败、不同版本和构造边界数据都保留为不完整。

已测：门禁拒绝、符号链接、预算前置拒绝、账本顺序/失败额度/每缓存上限/锁/损坏/累计不一致、不同并发分组、完整计划覆盖与缺失拒绝，以及真实小负载读写/随机/小文件、微型账本依赖链、官方CPU/RSS解析及自有进程组超时。真实blntfs新建128MiB镜像分别完成当前UID私有祖先、管理员助手root/ACL两种外层隔离、内部4MiB顺序写/验证/完整读回和正常分离；入口见[镜像验收说明](../System/性能隔离镜像说明.md)。未验收：真实外置NTFS执行、正式1008GiB全套、Paragon对比、跨驱动/Windows复读、掉电安全、连续系统CPU/内存时间序列采样。不得发布速度领先或功能等价结论。
