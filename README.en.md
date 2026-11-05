# NTFS 畅写 · NTFS WriteFlow

[完整介绍与截图](README.md) · [下载0.3.0兼容预览](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.3.0) · [版本说明](发布/版本说明.md)

**0.3.1候选尚未发布，当前下载仍为0.3.0。** 免费开源的macOS NTFS桌面应用，用中文界面呈现卷状态、只读／读写、Finder访问、正常卸载、整盘推出与后台管理。

0.3.1按系统与访问模式选择三种后端：15.4～26.3只读使用系统原生NTFS、读写FSKit；26.4起两种模式均FSKit；13～15.3使用用户安装批准的官方macFUSE。FSKit及macFUSE共用随包NTFS-3G，系统原生只读不经过该引擎。15.4～26.3所有RO／RW请求经管理员服务；26.0～26.3的RW系统命令与可信`SUDO_UID`发现方式保持，26及以上保留`funmount`卸载。

本轮五项变化：

- 修正15.4的挂载发现与独立用户身份桥接，旧系统只读改用原生NTFS；自动管理仍要求明确启用。
- 旧系统受管FSKit读写增加本次挂载的内部准备证明；缺少证明时显示“写入未就绪”，被动刷新重新核对挂载实例，拒绝沿用迟到的旧证明。
- 设置／诊断可滚动到底，长说明及配置、刷新、导出按钮可达。
- Apple虚拟机13～15.3明确提示macFUSE内核路径不可用，不把运行库就绪当挂载能力。
- 不支持Interix字符／块设备、FIFO和socket，未知挂载事务保留票据并阻止同整盘重复请求。

原生只读69项、身份桥接72项、受管发现85项的两架构检查及完整核心／模型回归通过，未决组合独立审查已闭环；真实引擎和普通FSVolume回归通过。**15.4旧候选实际写入EIO、正常卸载失败，新候选仍待完整链复验；握手与准确状态已通过双架构开发回归，预检拒绝保RO及先同步后卸载已通过回归和独立审查，新通用候选完成构建签名。26.0～26.3只有策略／模拟回归，没有对应实际系统通过。** 13.7.4／14.0安装、窗口与导出分项已验证，兼容VFS未通过；初始SIP disabled，不能代表默认安全实体机，Rosetta也不代表Intel硬件。

旧FSKit读写的`nosuid`／`nodev`／`nobrowse`未全部保留；拒绝特殊项、不呈现setuid／setgid是独立约束，不证明内核安全标志生效。详见[0.3.1发行草案](发布/0.3.1兼容预览发行说明.md)和[可核验说明](发布/0.3.1可核验说明.md)。Intel通用包和最低macOS13是0.3.0已有能力，本轮不重复列为新增。Issue #3仍待原环境复测。

[0.3.0 DMG](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.0/NTFS-WriteFlow-0.3.0-universal.dmg) · [0.3.0 ZIP](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.0/NTFS-WriteFlow-0.3.0-universal.zip)。同一Release提供完整对应源码、校验清单及验证附件；0.3.1最终签名、公证、源码对应和公开下载仍待核验。

[源码与签名](发布/开源说明.md) · [安装与卸载](发布/安装与卸载.md) · [许可](LICENSE) · [第三方组件](第三方组件说明.md)
