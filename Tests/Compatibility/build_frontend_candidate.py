#!/usr/bin/env python3
"""独立编译固定 NTFS-3G 的 macFUSE 前端；从不安装或运行文件系统。"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from prepare_candidate import verify_headers, verify_prepared

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/0.2.0/旧系统独立后端"
PIN = "7f0f841fc52cf719106c5c93bafe465004e36816"
RUNTIME_PATHS = (
    Path("/usr/local/lib/libfuse.2.dylib"),
    Path("/usr/local/lib/libosxfuse.2.dylib"),
    Path("/Library/Filesystems/macfuse.fs/Contents/Resources/lib/libfuse.2.dylib"),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true", help="仅编译两个架构和两个系统目标的前端对象")
    mode.add_argument("--link-only", action="store_true", help="仅当已有真实运行时及对象时尝试链接，绝不执行")
    parser.add_argument("--work-dir", type=Path, default=OUT, help="独立离线准备目录，必须位于仓库 build 内")
    args = parser.parse_args()
    output = args.work_dir.resolve()
    if not output.is_relative_to((ROOT / "build").resolve()):
        raise RuntimeError("独立准备目录必须位于仓库 build 内")
    if args.link_only:
        runtime = next((path for path in RUNTIME_PATHS if path.is_file()), None)
        if runtime is None:
            print("拒绝链接：未找到已安装的 macFUSE 用户态运行时。不会下载替身、安装驱动或尝试挂载。", file=sys.stderr)
            return 78
    source = ROOT / "ThirdParty/ntfs-3g"
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != PIN:
        raise RuntimeError("引擎固定提交不匹配")
    subprocess.run(["git", "-C", str(source), "diff", "--quiet"], check=True)
    subprocess.run(["git", "-C", str(source), "diff", "--cached", "--quiet"], check=True)
    verify_headers(output / "macfuse-headers")
    verify_prepared(output)
    records = []
    for minimum in ("13.0", "14.0"):
        for arch in ("arm64", "x86_64"):
            config = output / f"engine-{arch}-13"
            if not (config / "config.h").is_file():
                raise RuntimeError("先完成独立 13.0 目标引擎配置；不使用产品 15.4 配置冒充")
            if args.compile_only:
                for name in ("ntfs-3g", "lowntfs-3g", "ntfs-3g_common"):
                    target = output / f"{name}-{arch}-{minimum}.o"
                    command = ["xcrun", "clang", "-arch", arch, f"-mmacosx-version-min={minimum}", "-O2",
                               "-DHAVE_CONFIG_H=1", "-D_FILE_OFFSET_BITS=64", "-DFUSE_USE_VERSION=26",
                               "-I", str(config), "-I", str(output / "macfuse-headers"),
                               "-I", str(source / "include/ntfs-3g"), "-c", str(source / f"src/{name}.c"), "-o", str(target)]
                    result = subprocess.run(command, capture_output=True, text=True)
                    records.append({"架构": arch, "目标": minimum, "源": name, "命令": command,
                                    "退出码": result.returncode, "输出": result.stdout + result.stderr})
                    if result.returncode:
                        print(result.stderr, file=sys.stderr)
                        (output / "工具编译结果.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
                        return result.returncode
            else:
                for name in ("ntfs-3g", "lowntfs-3g"):
                    command = ["xcrun", "clang", "-arch", arch, f"-mmacosx-version-min={minimum}",
                               str(output / f"{name}-{arch}-{minimum}.o"), str(output / f"ntfs-3g_common-{arch}-{minimum}.o"),
                               str(config / "libntfs-3g/.libs/libntfs-3g.a"), str(runtime), "-framework", "CoreFoundation",
                               "-o", str(output / f"{name}-{arch}-{minimum}")]
                    result = subprocess.run(command, capture_output=True, text=True)
                    records.append({"架构": arch, "目标": minimum, "源": name, "命令": command,
                                    "退出码": result.returncode, "输出": result.stdout + result.stderr})
                    if result.returncode:
                        print(result.stderr, file=sys.stderr)
                        (output / "工具链接结果.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
                        return result.returncode
    (output / ("工具编译结果.json" if args.compile_only else "工具链接结果.json")).write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print("独立候选编译完成；没有安装、加载、运行文件系统，不能据此宣称旧系统或 Intel 实机支持。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
