#!/usr/bin/env python3
"""从本地固定源码和经校验的官方头文件准备独立双架构候选；全程离线，不安装、不运行文件系统。"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PIN = "7f0f841fc52cf719106c5c93bafe465004e36816"
HEADERS_PIN = "7a6cdd2b6e11071a706f4295aa931c65223ba953"
PINS = json.loads(Path(__file__).with_name("macfuse_header_pins.json").read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_headers(directory, pins=None):
    for name, digest in (PINS if pins is None else pins).items():
        path = directory / name
        if not path.exists() or not stat.S_ISREG(path.lstat().st_mode):
            raise RuntimeError(f"头文件或许可证必须是普通文件：{name}")
        if path.stat().st_size > 2 * 1024 * 1024 or sha(path) != digest:
            raise RuntimeError(f"固定官方来源校验失败：{name}")


def validate_output(path, root=ROOT):
    path = path.absolute()
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise RuntimeError("输出路径不可经过符号链接")
    path = path.resolve()
    build = (root / "build").resolve()
    if path.exists() or not path.is_relative_to(build) or path == build:
        raise RuntimeError("输出必须是仓库 build 内不存在的全新目录；保留历史记录，不覆盖")
    return path


def verify_source(source, pin=PIN):
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != pin:
        raise RuntimeError("引擎固定提交不匹配")
    for command in (["git", "-C", str(source), "diff", "--quiet"],
                    ["git", "-C", str(source), "diff", "--cached", "--quiet"]):
        subprocess.run(command, check=True)


def verify_prepared(output):
    manifest = json.loads((output / "离线准备结果.json").read_text())
    if manifest["引擎提交"] != PIN or manifest["官方头文件提交"] != HEADERS_PIN:
        raise RuntimeError("准备结果固定提交不匹配")
    required = {f"engine-{arch}-13/{name}" for arch in ("arm64", "x86_64")
                for name in ("config.h", "libntfs-3g/.libs/libntfs-3g.a")}
    if set(manifest["产物"]) != required:
        raise RuntimeError("准备结果缺失双架构配置或静态库记录")
    for name, digest in manifest["产物"].items():
        path = output / name
        if not path.resolve().is_relative_to(output.resolve()) or path.is_symlink() or sha(path) != digest:
            raise RuntimeError(f"准备产物校验失败：{name}")


def extract_source(raw, output):
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        members = archive.getmembers()
        for item in members:
            path = Path(item.name)
            if path.is_absolute() or ".." in path.parts or not (item.isfile() or item.isdir()):
                raise RuntimeError("源码归档含不安全路径或链接")
        archive.extractall(output, members=members, filter="data")


def configure_plan(arch, native, sdk):
    env = os.environ.copy()
    env.update(CC="clang", CFLAGS=f"-arch {arch} -isysroot {sdk} -mmacosx-version-min=13.0 -O2",
               LDFLAGS=f"-arch {arch} -isysroot {sdk} -mmacosx-version-min=13.0",
               LIBTOOLIZE="glibtoolize")
    command = ["../source/configure", "--disable-shared", "--enable-static", "--disable-ntfs-3g",
               "--enable-ntfsprogs", "--disable-crypto", "--disable-nls"]
    if arch != native:
        command.extend([f"--host={arch}-apple-darwin", f"--build={native}-apple-darwin"])
    return command, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headers-dir", required=True, type=Path, help="已下载的固定官方头文件及两份许可证目录")
    parser.add_argument("--output", required=True, type=Path, help="仓库 build 内全新目录")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("不以管理员身份运行独立兼容构建")
    output = validate_output(args.output)
    verify_headers(args.headers_dir)
    source = ROOT / "ThirdParty/ntfs-3g"
    verify_source(source)
    for tool in ("git", "xcrun", "clang", "make", "glibtoolize", "autoreconf"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"缺少本地构建工具：{tool}；本工具不会自动安装")
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    output.mkdir(parents=True)
    records = []

    def run(command, cwd, env=None):
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
        records.append({"命令": command, "目录": str(cwd), "退出码": result.returncode,
                        "CFLAGS": (env or {}).get("CFLAGS"), "LDFLAGS": (env or {}).get("LDFLAGS"),
                        "输出": result.stdout + result.stderr})
        (output / "准备命令记录.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
        if result.returncode:
            raise RuntimeError(f"独立构建失败，现场保留：{command[0]}；详见准备命令记录.json")
        return result.stdout

    versions = {tool: run([tool, "--version"], ROOT).splitlines()[0]
                for tool in ("git", "clang", "make", "glibtoolize", "autoreconf")}
    raw = subprocess.check_output(["git", "-C", str(source), "archive", PIN])
    (output / "固定引擎源码.tar").write_bytes(raw)
    staged = output / "source"
    staged.mkdir()
    extract_source(raw, staged)
    macro = ROOT / "ThirdParty/NTFSBridge/libgcrypt.m4"
    shutil.copyfile(macro, staged / "m4/libgcrypt.m4")
    run(["glibtoolize", "--force", "--copy", "--install"], staged)
    env = os.environ.copy()
    env["LIBTOOLIZE"] = "glibtoolize"
    run(["autoreconf", "-fi", "-I", "m4"], staged, env)
    headers = output / "macfuse-headers"
    headers.mkdir()
    for name in PINS:
        shutil.copyfile(args.headers_dir / name, headers / name)
    (headers / "来源.json").write_text(json.dumps({"提交": HEADERS_PIN, "头文件": [
        {"文件": name, "SHA256": digest} for name, digest in PINS.items()]}, ensure_ascii=False, indent=2))
    artifacts = {}
    for arch in ("arm64", "x86_64"):
        config = output / f"engine-{arch}-13"
        config.mkdir()
        command, env = configure_plan(arch, platform.machine(), sdk)
        run(command, config, env)
        run(["make", "-C", "libntfs-3g", "-j2"], config, env)
        for path in (config / "config.h", config / "libntfs-3g/.libs/libntfs-3g.a"):
            artifacts[str(path.relative_to(output))] = sha(path)
    manifest = {"引擎提交": PIN, "官方头文件提交": HEADERS_PIN, "固定源码归档SHA256": hashlib.sha256(raw).hexdigest(),
                "宏SHA256": sha(macro), "SDK": sdk, "工具版本": versions, "产物": artifacts,
                "边界": "离线编译候选；没有安装、挂载、卸载或运行后端，不代表旧系统或 Intel 实机通过"}
    (output / "离线准备结果.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    run([sys.executable, str(ROOT / "Tests/Compatibility/build_frontend_candidate.py"), "--compile-only",
         "--work-dir", str(output)], ROOT)
    print(f"独立离线准备完成，双架构静态库及12个前端对象：{output}")
    print(manifest["边界"])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
