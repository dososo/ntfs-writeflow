# NTFS畅写 · 简要介绍

[完整中文介绍](README.md) · [下载0.3.1兼容预览](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.3.1) · [更新记录](CHANGELOG.md)

NTFS畅写是免费开源的Mac应用，用一个原生界面查看NTFS磁盘状态、选择只读或读写、打开Finder，以及正常卸载和安全推出整盘。界面与维护文档使用中文。

## 为什么更新

第一次开源后，大家关心插盘能否自动处理、Intel和旧系统能否运行，以及数据安全和实际性能。我们把反馈与交付分开说明：

- **0.1.1**：首次公开预览，提供应用、源码、历史演示与安全推出结果。
- **0.2.0**：逐盘记忆只读／读写、插盘管理与可选登录启动，默认关闭；不是已经20轮实盘验证。
- **0.3.0**：Intel／Apple Silicon通用包，主程序及兼容前端最低macOS13；旧系统需自行安装批准macFUSE。这不是0.3.1首次新增。
- **0.3.1**：修正旧系统写入准备、状态和卸载收尾；15.4起漏列模块时可手动交系统核验，明确关闭、错误和自动门槛不放宽；设置和诊断更容易看全。

[每项反馈、改动、用法和限制](发布/用户反馈与版本迭代对照.md)。

## 安装与使用

从Release下载[DMG](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.1/NTFS-WriteFlow-0.3.1-universal.dmg)或[ZIP](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.1/NTFS-WriteFlow-0.3.1-universal.zip)，核对校验清单，放入固定的“应用程序”目录；按[安装说明](发布/安装与卸载.md)完成文件系统扩展（FSKit）和管理员服务授权，再选择只读或读写。遇到系统拒绝时停止，不强制接管。

要记住某块盘，在详情的“下次插入此盘”选择模式，再在设置打开“自动管理已选定的NTFS盘”并确认当前会话。用完正常卸载，要拔盘时等待安全推出结果。

## 先了解这些限制

当前是兼容预览。13～15.3使用用户另装的macFUSE，Apple虚拟机不支持这条内核路径；15.4～26.3只读用系统NTFS、读写用本应用的文件系统扩展，26.4起两种模式均用该扩展。

历史构建10在15.4 ARM客体的受控镜像完整链通过，不能移植为构建11同包实测。本机26.6.2构建11实盘挂载仍返回69，未启动我方模块或新增测试文件，未完成读写。[Issue #3](https://github.com/dososo/ntfs-writeflow/issues/3)仍打开。

Intel实体机、13／14实体兼容链、Windows、掉电和长期压力等未验；Rosetta不是Intel硬件证据。没有Paragon同条件实测对比，也没有大文件延迟或吞吐承诺。完整边界见[本版说明](发布/0.3.1兼容预览发行说明.md)和[可核验记录](发布/0.3.1可核验说明.md)。

[完整源码与核验附件](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.3.1) · [GPL-2.0许可](LICENSE) · [第三方组件](第三方组件说明.md)
