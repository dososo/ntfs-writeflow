# NTFS 畅写 · NTFS WriteFlow

[完整介绍与截图](README.md) · [下载 0.3.0 兼容预览版](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.3.0) · [版本说明](发布/版本说明.md)

免费开源的 macOS NTFS 应用，提供只读／读写挂载、Finder 访问、正常卸载、整盘推出、逐盘策略和登录后台管理。当前界面与维护文档为简体中文。

0.3.0（6）根据用户反馈交付 Intel 与 Apple Silicon 通用包，主应用最低 macOS 13。macOS 15.4 及以上使用随包 FSKit 扩展；macOS 13～15.3 使用随包 NTFS-3G 兼容前端与用户自行安装批准的官方 macFUSE。Apple Silicon 上的旧系统可能需要本人按 macFUSE 官方流程调整启动安全并批准内核扩展，本应用不会自动更改设置。

本轮已运行 ARM／Rosetta 真实文件镜像回调、故障注入、官方库 ABI 和参数解析及双架构构建；没有将其算作 Intel 硬件或 macOS 13～15.3／15.4 目标系统完整验收。保持预发布定位，自动管理默认关闭。完整支持路径、安装／回退和未覆盖项目见[兼容预览发行说明](发布/0.3.0兼容预览发行说明.md)与[可核验说明](发布/0.3.0可核验说明.md)。

[DMG 通用安装包](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.0/NTFS-WriteFlow-0.3.0-universal.dmg) · [ZIP 通用应用](https://github.com/dososo/ntfs-writeflow/releases/download/v0.3.0/NTFS-WriteFlow-0.3.0-universal.zip)。同一 Release 提供完整对应源码、校验清单和验证附件。

[从源码构建与签名](发布/开源说明.md) · [安装与卸载](发布/安装与卸载.md) · [许可](LICENSE) · [第三方组件](第三方组件说明.md)
