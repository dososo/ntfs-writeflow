# 独立兼容工程候选

这些工具不属于正式应用，不改变最低系统声明、签名、FSKit 或管理员卸载实现。它们不安装驱动、不更改安全配置、不挂载卷。可运行的测试只读取自有普通目录；前端候选只编译和链接，不执行。

`RetainedDiskObservation.swift` 保留磁盘、IOMedia、目录句柄并复查介质及挂载快照。其 `unchanged` 只表示本次观察一致，不能作为随后异步卸载的原子身份授权。没有 claim/unmount/eject 入口。纯策略测试覆盖换介质、离线、挂载实例/来源/位置和设备名变化、缺失身份、坏句柄，另对新建普通目录执行只读 fstatfs。运行：

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos13.0 Tests/Compatibility/RetainedDiskObservation.swift Tests/Compatibility/RetainedDiskObservationTests.swift -framework DiskArbitration -framework IOKit -o build/0.2.0/低系统候选验证记录/只读观察器测试
build/0.2.0/低系统候选验证记录/只读观察器测试
```

`build_frontend_candidate.py` 针对固定 NTFS-3G 官方源码及 macFUSE 官方 C API 头文件编译 13.0/14.0 × arm64/x86_64 的前端对象。它依赖本轮独立构建目录中的引擎配置/静态库与头文件，缺失时明确失败，不改正式引擎配置。运行：

```sh
python3 Tests/Compatibility/build_frontend_candidate.py --compile-only
python3 Tests/Compatibility/build_frontend_candidate.py --link-only
```

第二条只在本机已有 macFUSE 用户态运行时才链接；缺失返回 78，不下载替代品、不链接虚假 stub、不运行任何文件系统。即使链接成功也不代表内核后端、系统授权或旧系统可用；当前本机缺少运行时，真实挂载原型被明确阻断。

构建来源、官方头文件提交、12 个前端对象、独立 13.0 静态引擎和只读探测工具记录位于 `build/0.2.0/旧系统独立后端/`。该目录的生成产物未纳入源码，不能仅下载脚本就假定依赖已准备好。

本轮在当前 macOS 26 上运行官方 ARM 只读探测程序，仅访问刚创建的 64 MiB 普通 NTFS 镜像文件，探测前后 SHA256 不变；没有实际 VFS 挂载。Intel 程序仅编译和检查 Mach-O，没有执行。上游 `ntfs-3g.probe --readwrite` 会用可写 flags 打开引擎，不能拿来替换产品 RO|FORENSIC 的写前安全门禁；本轮从未执行该模式。

检验边界：这些结果证明代码/ABI 候选可继续研究，不能证明 macOS 13/14、Intel 实机或安全卸载支持。回滚只需不将独立候选集成到生产；正式源文件无本轮更改。没有设备操作验收，也没有发布兼容声明。
