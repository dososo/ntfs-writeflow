# Issue #3 候选修正与可核验说明

日期：2026-11-05。预览版本：0.2.0（构建 5）。[原始报告](https://github.com/dososo/ntfs-writeflow/issues/3)仍需目标环境复测，本文件不宣称实体盘故障已解决。

## 问题与机制依据

报告的失败发生在系统将代理块资源转换为真实资源时，早于本项目 NTFS 探测逻辑。旧管理员服务从系统守护进程直接启动固定挂载程序，仅传入 `SUDO_UID`。该值用于用户扩展发现，不能单独保证登录审计会话或 TCC 责任归属。

[Apple 挂载源码](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m)描述真实用户身份与扩展发现的关系。本机 `launchctl(1)` 手册说明 `asuser` 尽量采用目标用户的 bootstrap、异常服务及安全审计会话，不改变 UID。候选将二者组合，补齐子进程的用户会话上下文；不修改多线程助手本身的凭据。

[Apple DTS 的原始设备访问案例](https://developer.apple.com/forums/thread/802650)指出前台应用的范围授权与助手继承关系。[另一份 DTS 讨论](https://developer.apple.com/forums/thread/702907)也说明系统可能无法追踪助手责任链。因此本次会话修正是待验证假设，不能将加入审计会话等同于取得前台 TCC 授权。报告已启用可移除宗卷权限，不重复要求扩大后台完全磁盘访问权限。

## 可检查行为与实现

| 行为 | 文件与入口 | 验证 |
| --- | --- | --- |
| 固定在可信连接用户上下文启动系统挂载 | `HelperMedia.swift` 的 `HelperCommand.mountInvocation`；`PrivilegedMountService.swift` 的 `mount` | 会话回归先在旧实现运行失败，再于新实现通过 |
| UID、设备、路径和选项由已有受限请求派生 | 同一调用入口；UID仍取自验签连接 | 21项会话、调用、非法UID及凭据恢复检查通过 |
| 初始环境仅提供固定PATH、LANG和可信SUDO_UID | `HelperCommand.environment` | 环境白名单与非法程序拒绝检查；本机无盘asuser调用确认SUDO_UID被保留 |
| 非挂载查询不接收SUDO_UID，失败保留原保护 | `HelperCommand.run`、`PrivilegedMountEngine.mount` | 助手策略、ACL、弹出与句柄回归；不启用额外回退或强制操作 |
| 新增功能形成版本说明，构建号递增 | `project.yml`、`发布/版本说明.md` | 生成应用的实际版本与构建号回读；发行状态与通过范围分别记录 |

## 本轮验证与实际边界

本机为 macOS 26.6.2，没有外接测试盘。已执行现有自动挂载回归、管理员调用定向回归、助手策略与ACL、弹出与句柄回归、8项签名门禁，以及 Release 构建。独立只读审查未发现参数注入或信任边界扩大。

同用户无盘调用只证明初始环境能通过 `asuser` 传递，无法证明来自系统守护进程时实际切换了审计会话。临时签名构建不等于可分发应用、公证或扩展实际加载通过；相关发行验证必须单独记录。

复验命令：

```sh
bash Tests/Core/run_automount_tests.sh
bash Tests/Core/run_eject_tests.sh
python3 Tests/test_signing_gate.py
NTFS_BUILD_CONFIGURATION=Release bash script/build_and_run.sh --build-only
python3 script/package_release.py --check-only
```

定向会话回归沿用 `Tests/Core/README.md` 的助手源码编译方法，入口为 `Tests/Core/PrivilegedHelperSessionTests.swift`。本轮原始日志保存在工作副本 `build/issue-3/`，不包含在公开源码。

## 需要人工确认与未覆盖

- macOS 27.2 原报告实体 USB 盘的同条件只读／读写挂载、正常卸载及数据复读。
- 首次授权、拒绝、已授权、助手重启、应用重启，以及无有效用户会话时的拒绝。
- 新路由在真实系统守护进程内的审计会话与前台责任归属；本机无盘测试不能替代。
- 0.2.0实体二十轮、真实登录、跨账户及无竞争环境的稳定支持门槛；本次仅按明示限制的预览范围发行。
- Intel实机、旧系统、Windows、异常掉电和性能对比，没有新增支持结论。

原环境确认成功之前，Issue保持未解决状态。0.2.0按[预览范围](0.2.0预览发行说明.md)提供候选供测试；不能以公开分发、公证、构建或镜像通过自动关闭原报告。

## 最小回滚

源码撤回本次候选提交即可恢复原挂载路由和构建号，不强推共享历史。未安装预览版时无需改本机设置；如需回退，先关闭自动管理、等待已接受操作返回、正常卸载自有卷，再恢复备份的0.1.2应用。无需修改用户盘数据、设备节点权限或系统保护。
