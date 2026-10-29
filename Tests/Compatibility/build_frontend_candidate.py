#!/usr/bin/env python3
"""独立编译固定 NTFS-3G 的 macFUSE 前端；从不安装或运行文件系统。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/0.2.0/旧系统独立后端"
PIN = "7f0f841fc52cf719106c5c93bafe465004e36816"
HEADERS_PIN = "7a6cdd2b6e11071a706f4295aa931c65223ba953"
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
    args = parser.parse_args()
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
    manifest = json.loads((OUT / "macfuse-headers/来源.json").read_text())
    if manifest["提交"] != HEADERS_PIN:
        raise RuntimeError("官方头文件固定提交不匹配")
    for item in manifest["头文件"]:
        raw = (OUT / "macfuse-headers" / item["文件"]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != item["SHA256"]:
            raise RuntimeError("官方头文件校验不匹配")
    records = []
    for minimum in ("13.0", "14.0"):
        for arch in ("arm64", "x86_64"):
            config = OUT / f"engine-{arch}-13"
            if not (config / "config.h").is_file():
                raise RuntimeError("先完成独立 13.0 目标引擎配置；不使用产品 15.4 配置冒充")
            if args.compile_only:
                for name in ("ntfs-3g", "lowntfs-3g", "ntfs-3g_common"):
                    target = OUT / f"{name}-{arch}-{minimum}.o"
                    command = ["xcrun", "clang", "-arch", arch, f"-mmacosx-version-min={minimum}", "-O2",
                               "-DHAVE_CONFIG_H=1", "-D_FILE_OFFSET_BITS=64", "-DFUSE_USE_VERSION=26",
                               "-I", str(config), "-I", str(OUT / "macfuse-headers"),
                               "-I", str(source / "include/ntfs-3g"), "-c", str(source / f"src/{name}.c"), "-o", str(target)]
                    result = subprocess.run(command, capture_output=True, text=True)
                    records.append({"架构": arch, "目标": minimum, "源": name, "命令": command,
                                    "退出码": result.returncode, "输出": result.stdout + result.stderr})
                    if result.returncode:
                        print(result.stderr, file=sys.stderr)
                        (OUT / "工具编译结果.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
                        return result.returncode
            else:
                for name in ("ntfs-3g", "lowntfs-3g"):
                    command = ["xcrun", "clang", "-arch", arch, f"-mmacosx-version-min={minimum}",
                               str(OUT / f"{name}-{arch}-{minimum}.o"), str(OUT / f"ntfs-3g_common-{arch}-{minimum}.o"),
                               str(config / "libntfs-3g/.libs/libntfs-3g.a"), str(runtime), "-framework", "CoreFoundation",
                               "-o", str(OUT / f"{name}-{arch}-{minimum}")]
                    result = subprocess.run(command, capture_output=True, text=True)
                    records.append({"架构": arch, "目标": minimum, "源": name, "命令": command,
                                    "退出码": result.returncode, "输出": result.stdout + result.stderr})
                    if result.returncode:
                        print(result.stderr, file=sys.stderr)
                        (OUT / "工具链接结果.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
                        return result.returncode
    (OUT / ("工具编译结果.json" if args.compile_only else "工具链接结果.json")).write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print("独立候选编译完成；没有安装、加载、运行文件系统，不能据此宣称旧系统或 Intel 实机支持。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
