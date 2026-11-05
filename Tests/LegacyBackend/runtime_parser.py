#!/usr/bin/env python3
"""用官方解包库验证ABI及参数解析；环境覆盖只作用于普通用户测试进程。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def snapshot(payload):
    paths = [payload / "usr/local/lib/libfuse.2.dylib"]
    frameworks = payload / "Library/Filesystems/macfuse.fs/Contents/Frameworks"
    paths.extend(sorted(frameworks.rglob("*")))
    result = {}
    for path in paths:
        if path.is_symlink():
            result[str(path.relative_to(payload))] = {"链接": str(path.readlink())}
        elif path.is_file():
            result[str(path.relative_to(payload))] = {"SHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                                     "权限": oct(path.stat().st_mode & 0o7777)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True, help="官方Core.pkg只读展开的Payload目录")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise SystemExit("仅允许普通用户运行，不需要管理员权限。")
    payload = args.payload.resolve()
    library = payload / "usr/local/lib/libfuse.2.dylib"
    frameworks = payload / "Library/Filesystems/macfuse.fs/Contents/Frameworks"
    if not library.is_file() or not frameworks.is_dir():
        parser.error("缺少已展开的官方库或Frameworks目录；本工具不会下载或安装。")
    os.chdir(ROOT)
    base = ROOT / "build/0.3.0/旧后端"
    base.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="官方库解析-", dir=base))
    mountpoint = work / "仅解析路径"
    mountpoint.mkdir(mode=0o700)
    third_party_before = snapshot(payload)
    source_before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted((ROOT / "Sources/LegacyBackend").glob("*.[ch]"))}
    records = []
    environment = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_")}
    environment["DYLD_FRAMEWORK_PATH"] = str(frameworks)
    status = "通过"
    try:
        for arch in ("arm64", "x86_64"):
            executable = work / ("无挂载解析-" + arch)
            compiler = ["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=13.0", "-D_FILE_OFFSET_BITS=64",
                        "-Wall", "-Wextra", "-Werror", "-I", "ThirdParty/MacFUSEHeaders", "-I", "Sources/LegacyBackend",
                        "Tests/LegacyBackend/runtime_parser.c", "Sources/LegacyBackend/legacy_options.c", "-o", str(executable)]
            compiled = subprocess.run(compiler, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (work / ("编译-" + arch + ".log")).write_bytes(compiled.stdout)
            compiled.check_returncode()
            # 直接运行薄Mach-O；经SIP保护的系统arch程序可能剥离DYLD环境，不作包装。
            result = subprocess.run([str(executable), str(library), str(mountpoint)], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
            (work / ("官方库解析-" + arch + ".log")).write_bytes(result.stdout)
            records.append({"架构": arch, "退出码": result.returncode, "输出": result.stdout.decode(errors="replace"),
                            "测试命令": [str(executable), str(library), str(mountpoint)]})
            if result.returncode == 78:
                status = "受阻：dyld未允许从只读缓存解析依赖"
                break
            result.check_returncode()
            if arch == "x86_64" and "Rosetta=1" not in result.stdout.decode():
                raise RuntimeError("x86_64运行未记录Rosetta翻译状态")
        if snapshot(payload) != third_party_before:
            raise RuntimeError("官方库或框架字节/链接/权限发生变化")
        if any(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest for name, digest in source_before.items()):
            raise RuntimeError("测试期间生产C源码发生变化")
        report = {"结果": status, "架构": records, "仅测试进程DYLD_FRAMEWORK_PATH": str(frameworks),
                  "第三方字节链接权限不变": True, "生产C源码不变": True, "第三方快照": third_party_before,
                  "生产源SHA256": source_before,
                  "仅调用入口": ["fuse_version", "fuse_parse_cmdline", "fuse_opt_parse", "fuse_opt_free_args"],
                  "未覆盖": ["fuse_mount/fuse_main", "MFMount挂载与内核加载", "系统VFS与Finder", "root生产子程序与旧系统实机"]}
        (work / "结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"{status}：{work}")
        return 0 if status == "通过" else 78
    except BaseException as error:
        (work / "失败.json").write_text(json.dumps({"结果": "失败", "错误": str(error), "架构": records}, ensure_ascii=False, indent=2))
        raise


if __name__ == "__main__":
    raise SystemExit(main())
