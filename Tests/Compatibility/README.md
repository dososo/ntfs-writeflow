# 独立兼容工程候选

这些工具不属于正式应用，不改变最低系统声明、签名、FSKit 或管理员卸载实现。它们不安装驱动、不更改安全配置、不挂载卷。可运行的测试只读取自有普通目录；前端候选只编译和链接，不执行。

`RetainedDiskObservation.swift` 保留磁盘、IOMedia、目录句柄并复查介质及挂载快照。其 `unchanged` 只表示本次观察一致，不能作为随后异步卸载的原子身份授权。没有 claim/unmount/eject 入口。纯策略测试覆盖换介质、离线、挂载实例/来源/位置和设备名变化、缺失身份、坏句柄，另对新建普通目录执行只读 fstatfs。运行：

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos13.0 Tests/Compatibility/RetainedDiskObservation.swift Tests/Compatibility/RetainedDiskObservationTests.swift -framework DiskArbitration -framework IOKit -o build/0.2.0/低系统候选验证记录/只读观察器测试
build/0.2.0/低系统候选验证记录/只读观察器测试
```

`prepare_candidate.py` 已补齐全新的离线准备入口，不再依赖手工生成的引擎配置。需要本地 Python 3.12+、Xcode 命令行工具、Git、Make、Autoconf、Automake、GNU Libtool；工具不会自动安装依赖。固定 NTFS 源在 `ThirdParty/ntfs-3g`，提交必须为 `7f0f841fc52cf719106c5c93bafe465004e36816` 且已跟踪文件无改动。macFUSE 的 10 份官方头文件及两份许可证使用 `macfuse_header_pins.json` 中的固定 SHA256，不能用缓存目录自己提供的散列表冒充校验。

若尚无缓存，先单独联网获取官方固定提交的文本源码及许可证（不下载二进制、不安装驱动），之后可以完全离线构建。缓存目录必须全新，失败现场保留：

```sh
python3 - <<'PYFETCH'
import hashlib, json, subprocess
from pathlib import Path
pin = "7a6cdd2b6e11071a706f4295aa931c65223ba953"
pins = json.loads(Path("Tests/Compatibility/macfuse_header_pins.json").read_text())
out = Path("build/0.2.0/官方头文件缓存")
out.mkdir(parents=True, exist_ok=False)
for name, digest in pins.items():
    source = name if name.startswith("COPYING") else "include/" + name
    url = "https://raw.githubusercontent.com/macfuse/library/" + pin + "/" + source
    subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--max-time", "30", url, "--output", str(out / name)], check=True)
    assert hashlib.sha256((out / name).read_bytes()).hexdigest() == digest, name
print("12份固定官方文本校验通过")
PYFETCH
```

正式准备命令只读取本地来源，输出限定在本仓库 build 下的全新目录；拒绝重用目录、符号链接路径、损坏头文件和源码提交变化。示例使用新的目录名，若已有则换名，不删除历史现场：

```sh
python3 -m unittest discover -s Tests/Compatibility -p test_prepare_candidate.py
python3 Tests/Compatibility/prepare_candidate.py --headers-dir build/0.2.0/官方头文件缓存 --output build/0.2.0/独立离线候选-首次
python3 Tests/Compatibility/build_frontend_candidate.py --compile-only --work-dir build/0.2.0/独立离线候选-首次
python3 Tests/Compatibility/build_frontend_candidate.py --link-only --work-dir build/0.2.0/独立离线候选-首次
```

准备入口通过 git archive 固定提交，在独立副本生成配置；ARM/Intel 分目录配置 13.0 静态引擎，再编译 13.0/14.0 × 两架构的 12 个官方前端对象。既有自有 libgcrypt 宏只复制到候选副本；不改引擎源或产品 build/engine，不运行 ntfs-3g、不做全局安装。记录命令、编译输出、工具版本、SDK、源码/宏/库/config.h SHA256；前端重跑时检查准备产物指纹。这是流程可重复，不宣称不同 SDK/工具链生成逐字节相同的二进制。

链接命令只在本机已有 macFUSE 用户态运行时才链接；缺失返回 78，不下载替代品、不链接虚假 stub、不运行任何文件系统。即使链接成功也不代表内核后端、系统授权或旧系统可用；当前本机缺少运行时，真实挂载原型被明确阻断。

前轮构建来源、官方头文件提交、12 个前端对象、独立 13.0 静态引擎和只读探测工具记录位于 `build/0.2.0/旧系统独立后端/`。该目录的生成产物未纳入源码，不能仅下载脚本就假定依赖已准备好。

本轮在当前 macOS 26 上运行官方 ARM 只读探测程序，仅访问刚创建的 64 MiB 普通 NTFS 镜像文件，探测前后 SHA256 不变；没有实际 VFS 挂载。Intel 程序仅编译和检查 Mach-O，没有执行。上游 `ntfs-3g.probe --readwrite` 会用可写 flags 打开引擎，不能拿来替换产品 RO|FORENSIC 的写前安全门禁；本轮从未执行该模式。

检验边界：这些结果证明代码/ABI 候选可继续研究，不能证明 macOS 13/14、Intel 实机或安全卸载支持。回滚只需不将独立候选集成到生产；正式源文件无本轮更改。没有设备操作验收，也没有发布兼容声明。

本轮实际运行：15 项准备边界测试通过，使用前轮已校验缓存在全新 `build/0.2.0/离线可复现候选-20261029/` 真实完成双架构静态库及 12 对象编译；链接缺运行时退出 78。生产两架构库 SHA 和引擎提交/差异前后一致。所有测试临时目录保留，不批量清理。

`CtlByFSIDABI.c` 仅静态断言公开结构/常量，不含 sysctl 或卸载调用。13.0/14.0/15.4 × 两架构的六个对象已编译；详细官方源码研究与未闭合的编号复用窗口见[旧系统卸载补充研究](../../发布/旧系统卸载补充研究.md)。编译例：

```sh
xcrun clang -arch arm64 -mmacosx-version-min=15.4 -Wall -Wextra -Werror -c Tests/Compatibility/CtlByFSIDABI.c -o build/0.2.0/兼容后续研究/编号ABI-arm64-15.4.o
```


## Intel 完整应用与 15.4 扩展隔离候选

`build_app_candidate.py` 将明确 Git 提交中的必要源文件归档到全新副本，另展开固定 NTFS 源并复制已校验的双架构 config.h/静态库；在副本运行 XcodeGen 和 Xcode 构建，不复用生产生成工程或派生数据。除前述工具外需本地 XcodeGen。`--revision` 必须明确提供 HEAD 或提交号，未提交文件不会进入候选，结果绑定解析后的完整提交号。

```sh
python3 -m unittest discover -s Tests/Compatibility -p 'test_*.py'
python3 Tests/Compatibility/build_app_candidate.py --mode intel26 --revision HEAD --engine-dir build/0.2.0/离线可复现候选-20261029 --output build/0.2.0/Intel完整候选-新的验收
python3 Tests/Compatibility/build_app_candidate.py --mode mac15-prototype --revision HEAD --engine-dir build/0.2.0/离线可复现候选-20261029 --output build/0.2.0/15.4隔离候选-新的验收
```

第一种模式真实构建完整 Intel Release 应用，并逐个检查包内 Mach-O：必须恰好有宿主、FSKit 扩展、管理员助手，均为 x86_64、最低系统26；宿主和扩展 Info.plist 最低系统、三个组件身份与助手嵌入标识、LaunchDaemon 受限服务配置、展示图标均核验。另检查宿主/助手仍导入 `_funmount`，没有开发机私有动态库依赖。成功退出0，只表示完整包静态通过，不是 Intel 实机、签名、公证或授权通过。

第二种模式仅在副本将已知的26可用存储属性改为相同可用性约束的计算属性；唯一匹配失败就停止。先独立构建、链接 ARM 和 Intel 的完整 FSKit 扩展并核验最低系统15.4，再构建两架构完整应用。只有编译错误全部是 `funmount` 仅26可用时，才记录预期安全阻断并退出78；其他错误或意外成功均失败退出1。保留正式 FD 卸载代码，不写 stub、不退回路径卸载，不改生产最低系统或签名。扩展候选可以完整链接，完整旧系统应用仍未可用。

本轮冻结基线 `27fe68ece08f9b2fba20b93cce23a4e5bbd462f3` 实际结果：Intel26完整应用和追加静态检查通过；15.4双架构扩展链接通过，完整应用均因 `funmount` 退出65，工具总退出78；兼容工具共24项测试通过。生成目录分别是 `build/0.2.0/Intel完整隔离候选-27fe68e/` 和 `build/0.2.0/15.4完整隔离原型-27fe68e/`。这些结果不覆盖基线之后的源代码，最终提交后需用新提交号和全新输出目录复跑。

核查文件：`候选结果.json` 记录应用/引擎提交、输入归档及工具 SHA、构建命令/退出码/日志、产品路径/哈希；`仅副本属性适配.patch` 便于检查修改范围。未覆盖目标机启动、FSKit系统加载、服务授权、磁盘读写/弹出、旧系统运行与性能。最小回滚为不集成候选工具及副本；所有生成证据保留，生产源和部署要求没有本轮变更。
