#!/usr/bin/env python3
"""在全新副本构建 Intel 完整应用或 15.4 属性候选；只静态验收，不启动、签名、安装或操作磁盘。"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from prepare_candidate import ROOT, PIN, extract_source, sha, validate_output, verify_prepared, verify_source

INPUTS = ("Sources", "Configuration", "ThirdParty/FSKitAdapter", "ThirdParty/NTFSBridge", "project.yml",
          "LICENSE", "第三方组件说明.md", "script/embed_helper_configuration.sh")
OLD_PROPERTY = "    @available(macOS 26.0, *)\n    var enableOpenUnlinkEmulation: Bool = true"
NEW_PROPERTY = """    private var openUnlinkEmulationEnabled: Bool = true

    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool {
        get { openUnlinkEmulationEnabled }
        set { openUnlinkEmulationEnabled = newValue }
    }"""


def validate_revision(value):
    if value != "HEAD" and re.fullmatch(r"[0-9a-f]{7,40}", value) is None:
        raise ValueError("基线仅接受 HEAD 或明确的十六进制提交号")
    return value


def adapt_property(text):
    if text.count(OLD_PROPERTY) != 1:
        raise RuntimeError("属性实现与已审查原型不同，拒绝盲目替换")
    return text.replace(OLD_PROPERTY, NEW_PROPERTY)


def validate_macho_metadata(architectures, build, arch, minimum):
    if architectures.split() != [arch] or re.findall(r"\bplatform\s+(\S+)", build) != ["MACOS"]:
        raise RuntimeError("产物架构或平台与候选不符")
    if re.findall(r"\bminos\s+(\S+)", build) != [minimum]:
        raise RuntimeError("产物最低系统与候选不符")


def validate_bundle_metadata(app, extension, daemon):
    expected = ((app.get("CFBundleIdentifier"), "com.blteam.ntfsworkbench"),
                (app.get("CFBundleExecutable"), "NTFSWorkbench"), (app.get("LSMinimumSystemVersion"), "26.0"),
                (extension.get("CFBundleIdentifier"), "com.blteam.ntfsworkbench.filesystem"),
                (extension.get("CFBundleExecutable"), "NTFSFileSystem"),
                (extension.get("LSMinimumSystemVersion"), "26.0"),
                (daemon.get("Label"), "com.blteam.ntfsworkbench.mount-helper"),
                (daemon.get("BundleProgram"), "Contents/Library/HelperTools/NTFSWriteFlowMountHelper"),
                (daemon.get("AssociatedBundleIdentifiers"), ["com.blteam.ntfsworkbench"]),
                (daemon.get("MachServices"), {"com.blteam.ntfsworkbench.mount-helper": True}))
    attributes = extension.get("EXAppExtensionAttributes", {})
    expected += ((attributes.get("EXExtensionPointIdentifier"), "com.apple.fskit.fsmodule"),
                 (attributes.get("FSShortName"), "blntfs"))
    if any(actual != desired for actual, desired in expected):
        raise RuntimeError("应用、扩展或助手配置身份不符")


def is_safety_block(code, output):
    errors = [line for line in output.splitlines() if "error:" in line]
    return code != 0 and bool(errors) and all("'funmount' is only available in macOS 26.0 or newer" in line for line in errors)


def validate_dependencies(output):
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency and (not dependency.startswith(("/System/Library/", "/usr/lib/")) or ".." in Path(dependency).parts):
            raise RuntimeError("候选含非系统动态依赖，不能作为独立完整包")


def decode_embedded_plist(text):
    chunks = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or re.fullmatch(r"[0-9a-fA-F]{8,16}", parts[0]) is None or any(re.fullmatch(r"[0-9a-fA-F]{2}", part) is None for part in parts[1:]):
            raise RuntimeError("助手嵌入配置不是有效十六进制段")
        chunks.extend(parts[1:])
    try:
        result = plistlib.loads(bytes.fromhex("".join(chunks)).rstrip(b"\0"))
    except Exception as error:
        raise RuntimeError("助手嵌入配置缺失或损坏") from error
    if not isinstance(result, dict):
        raise RuntimeError("助手嵌入配置必须是字典")
    return result


def static_audit(app, arch, minimum):
    def read_plist(path):
        with path.open("rb") as stream:
            return plistlib.load(stream)
    extension = app / "Contents/Extensions/NTFSFileSystem.appex"
    daemon = app / "Contents/Library/LaunchDaemons/com.blteam.ntfsworkbench.mount-helper.plist"
    validate_bundle_metadata(read_plist(app / "Contents/Info.plist"), read_plist(extension / "Contents/Info.plist"), read_plist(daemon))
    if not (app / "Contents/Resources/WriteFlow.icns").is_file():
        raise RuntimeError("完整应用缺少展示图标")
    expected = {app / "Contents/MacOS/NTFSWorkbench", extension / "Contents/MacOS/NTFSFileSystem",
                app / "Contents/Library/HelperTools/NTFSWriteFlowMountHelper"}
    found = set()
    records = []
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                         b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
            continue
        if path.is_symlink():
            raise RuntimeError("包内 Mach-O 不能是外部符号链接")
        architectures = subprocess.check_output(["lipo", "-archs", str(path)], text=True)
        build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(path)], text=True)
        validate_macho_metadata(architectures, build, arch, minimum)
        dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
        validate_dependencies(dependencies)
        symbols = subprocess.check_output(["nm", "-u", str(path)], text=True)
        if path in expected and path.name != "NTFSFileSystem" and not re.search(r"(?m)^_funmount$", symbols):
            raise RuntimeError("宿主或助手未保留正式 FD 卸载导入")
        embedded = None
        if path.name == "NTFSWriteFlowMountHelper":
            text = subprocess.check_output(["otool", "-X", "-s", "__TEXT", "__info_plist", str(path)], text=True)
            embedded = decode_embedded_plist(text).get("CFBundleIdentifier")
            if embedded != "com.blteam.ntfsworkbench.mount-helper":
                raise RuntimeError("实际助手可执行文件的嵌入标识错误")
        records.append({"助手嵌入标识": embedded, "文件": str(path.relative_to(app)), "SHA256": sha(path), "架构": architectures.strip(),
                        "系统目标": build, "动态依赖": dependencies, "保留FD卸载": "_funmount" in symbols})
        found.add(path)
    if found != expected:
        raise RuntimeError("完整应用的三个 Mach-O 缺失或出现未审查附加程序")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("intel26", "mac15-prototype"), required=True)
    parser.add_argument("--revision", type=validate_revision, required=True, help="明确提交基线，不包含未提交文件")
    parser.add_argument("--engine-dir", type=Path, required=True, help="prepare_candidate.py 已完成的双架构引擎目录")
    parser.add_argument("--output", type=Path, required=True, help="仓库 build 内全新目录")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("不使用管理员身份构建候选")
    output = validate_output(args.output)
    engine = args.engine_dir.resolve()
    verify_prepared(engine)
    ntfs = ROOT / "ThirdParty/ntfs-3g"
    verify_source(ntfs)
    for tool in ("git", "xcodegen", "xcodebuild", "xcrun", "lipo", "otool", "nm"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"缺少本地工具：{tool}；不会自动安装")
    revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--verify", args.revision + "^{commit}"], text=True).strip()
    output.mkdir(parents=True)
    records = []
    manifest = {"模式": args.mode, "应用基线": revision, "引擎提交": PIN, "引擎准备记录SHA256": sha(engine / "离线准备结果.json"),
                "工具源码SHA256": sha(Path(__file__)), "操作记录": records,
                "边界": "仅固定提交的隔离交叉构建与静态检查；未运行、签名、安装或挂载，不代表目标机验收"}

    def save():
        (output / "候选结果.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))

    def run(command, cwd=ROOT, log=None, must_pass=True):
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
        text = result.stdout + result.stderr
        if log:
            (output / log).write_text(text)
        records.append({"命令": command, "目录": str(cwd), "退出码": result.returncode, "日志": log,
                        "输出": text if not log else None})
        save()
        if must_pass and result.returncode:
            raise RuntimeError(f"候选步骤失败：{command[0]}；现场及日志保留于 {output}")
        return result.returncode, text

    for command in (["xcodebuild", "-version"], ["xcodegen", "--version"], ["xcrun", "--show-sdk-version"]):
        run(command)
    raw = subprocess.check_output(["git", "-C", str(ROOT), "archive", revision, *INPUTS])
    manifest["应用归档SHA256"] = hashlib.sha256(raw).hexdigest()
    (output / "固定应用源码.tar").write_bytes(raw)
    staged = output / "source"
    staged.mkdir()
    extract_source(raw, staged)
    ntfs_raw = subprocess.check_output(["git", "-C", str(ntfs), "archive", PIN])
    manifest["引擎归档SHA256"] = hashlib.sha256(ntfs_raw).hexdigest()
    extract_source(ntfs_raw, staged / "ThirdParty/ntfs-3g")
    for arch in ("arm64", "x86_64"):
        destination = staged / f"build/engine/{arch}"
        (destination / "libntfs-3g/.libs").mkdir(parents=True)
        source = engine / f"engine-{arch}-13"
        for name in ("config.h", "libntfs-3g/.libs/libntfs-3g.a"):
            shutil.copyfile(source / name, destination / name)
    if args.mode == "mac15-prototype":
        path = staged / "ThirdParty/FSKitAdapter/ntfs3gVolume.swift"
        original = path.read_text()
        adapted = adapt_property(original)
        path.write_text(adapted)
        (output / "仅副本属性适配.patch").write_text("".join(difflib.unified_diff(original.splitlines(True), adapted.splitlines(True),
            fromfile="原固定源码/ntfs3gVolume.swift", tofile="候选副本/ntfs3gVolume.swift")))
    run(["xcodegen", "generate", "--spec", "project.yml"], staged, "工程生成.log")

    def build(scheme, arch, minimum, label):
        derived = output / label
        command = ["xcodebuild", "-project", str(staged / "NTFSWorkbench.xcodeproj"), "-scheme", scheme,
                   "-configuration", "Release", "-derivedDataPath", str(derived), f"ARCHS={arch}", "ONLY_ACTIVE_ARCH=NO",
                   f"MACOSX_DEPLOYMENT_TARGET={minimum}", "CODE_SIGNING_ALLOWED=NO", "build"]
        code, text = run(command, staged, label + ".log", must_pass=False)
        return code, text, derived / "Build/Products/Release"

    if args.mode == "intel26":
        code, _, products = build("NTFSWorkbench", "x86_64", "26.0", "Intel26完整应用")
        if code:
            raise RuntimeError("Intel26完整候选构建失败；不能标记静态通过")
        app = products / "NTFSWorkbench.app"
        manifest["完整包静态检查"] = static_audit(app, "x86_64", "26.0")
        manifest["应用路径"] = str(app)
        manifest["结果"] = "完整 Intel26 应用静态通过，目标机/签名/FSKit授权待验"
        save()
        print(manifest["结果"])
        return 0

    results = []
    for arch in ("arm64", "x86_64"):
        code, _, products = build("NTFSFileSystem", arch, "15.4", f"属性候选扩展-{arch}")
        if code:
            raise RuntimeError(f"15.4 {arch} 扩展候选构建失败；不是可忽略的完整应用安全阻断")
        executable = products / "NTFSFileSystem.appex/Contents/MacOS/NTFSFileSystem"
        validate_macho_metadata(subprocess.check_output(["lipo", "-archs", str(executable)], text=True),
            subprocess.check_output(["xcrun", "vtool", "-show-build", str(executable)], text=True), arch, "15.4")
        code, text, _ = build("NTFSWorkbench", arch, "15.4", f"完整15.4安全阻断-{arch}")
        known = is_safety_block(code, text)
        results.append({"架构": arch, "扩展链接": "通过", "扩展SHA256": sha(executable),
                        "完整应用退出码": code, "仅已知FD卸载阻断": known})
        manifest["15.4分项结果"] = results
        save()
        if not known:
            raise RuntimeError("15.4完整应用结果与预期安全阻断不符；保留日志并停止，不冒充支持")
    manifest["结果"] = "15.4双架构扩展副本链接通过；完整应用因funmount26安全接口明确阻断"
    save()
    print(manifest["结果"])
    return 78


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
