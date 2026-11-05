#!/usr/bin/env python3
"""只创建私有HFS+镜像，执行生产旧路径卸载原语；不碰已有卷或管理员服务。"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    os.chdir(ROOT)
    if os.geteuid() == 0:
        raise SystemExit("请以普通用户运行；此测试不需要管理员权限。")
    evidence = ROOT / "build/0.3.0/旧卸载原语"
    evidence.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="验收-", dir=evidence))
    private = Path(tempfile.mkdtemp(prefix="WriteFlow-旧卸载-", dir="/private/tmp"))
    records = []

    def command(args):
        result = subprocess.run([str(x) for x in args], capture_output=True)
        records.append({"命令": [str(x) for x in args], "退出码": result.returncode,
                        "错误": result.stderr.decode(errors="replace")})
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return result.stdout

    current_device = None
    try:
        for arch in ("arm64", "x86_64"):
            executable = output / ("真实卸载-" + arch)
            shared = sorted((ROOT / "Sources/HelperShared").glob("*.swift"))
            command(["xcrun", "swiftc", "-target", arch + "-apple-macos13.0", "-swift-version", "6",
                     "-warnings-as-errors", "-import-objc-header", "Sources/PrivilegedHelper/Helper-Bridging-Header.h",
                     "Sources/Core/VolumeRecord.swift", *shared, "Sources/App/Services/MountedFileSystemReader.swift",
                     "Sources/PrivilegedHelper/HelperMedia.swift", "Sources/PrivilegedHelper/HelperNamespace.swift",
                     "Sources/PrivilegedHelper/ManagedUnmount.swift", "Tests/Core/LegacyUnmountSystemTests.swift",
                     "-o", executable])
            image, mount = output / (arch + ".dmg"), private / arch
            mount.mkdir(mode=0o700)
            command(["hdiutil", "create", "-size", "32m", "-fs", "HFS+", "-volname", "WriteFlowLegacyTest", image])

            def attach(readonly=False):
                nonlocal current_device
                arguments = ["hdiutil", "attach", "-plist", "-nobrowse", "-owners", "on", "-mountpoint", mount]
                if readonly:
                    arguments.append("-readonly")
                result = plistlib.loads(command(arguments + [image]))
                entities = result["system-entities"]
                current_device = next(item["dev-entry"] for item in entities
                                      if item.get("content-hint") in {"Apple_partition_scheme", "GUID_partition_scheme"})
                return next(item["dev-entry"] for item in entities if item.get("mount-point") == str(mount))

            partition = attach()
            result = command(["arch", "-" + arch, executable, mount, partition])
            (output / (arch + "-卸载.log")).write_bytes(result)
            command(["hdiutil", "detach", current_device])
            current_device = None
            attach(readonly=True)
            if (mount / "卸载前写入.txt").read_bytes() != "真实同步与正常卸载\n".encode():
                raise RuntimeError("重挂载内容不一致")
            command(["hdiutil", "detach", current_device])
            current_device = None
            mount.rmdir()
        result = {"结果": "通过", "架构": ["arm64", "x86_64（Rosetta）"], "记录": records,
                  "边界": "当前macOS26执行13目标程序。真实HFS+fsync/path unmount和只读重挂复读；租约为自有0700目录替身，不是root生产链、macFUSE或旧系统实机。"}
        (output / "结果.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        private.rmdir()
        print(output / "结果.json")
    except BaseException:
        if current_device:
            subprocess.run(["hdiutil", "detach", current_device], check=False)
        (output / "失败记录.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
        raise


if __name__ == "__main__":
    main()
