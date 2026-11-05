#!/usr/bin/env python3
"""显式输入官方制品，复跑ARM与Rosetta运行时信任及C→Swift回执检查；不安装、不加载、不操作设备。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit("用法：python3 Tests/Core/run_legacy_security_tests.py <官方展开Payload目录> <已签名本应用助手> [C回执公共前缀]\n省略第三参数时，从当前C writer源码重新生成两架构回执。")
    if os.geteuid() == 0:
        raise SystemExit("本测试只允许普通用户执行，不需要管理员权限。")
    payload, helper = (Path(value).resolve() for value in sys.argv[1:3])
    required = [payload / "usr/local/lib/libfuse.2.dylib", payload / "Library/Filesystems/macfuse.fs", helper]
    if any(not path.exists() for path in required):
        raise SystemExit("缺少前置：请提供真实官方Payload目录及本应用已签名助手，不能使用自定义假库或假程序。")
    existing_prefix = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else None
    os.chdir(ROOT)
    output = ROOT / "build/legacy-security-tests"
    output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="可复现验证-", dir=output))
    commands, records = [], []

    def run(name, arguments, expected=0):
        result = subprocess.run([str(value) for value in arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (run_dir / (name + ".out")).write_bytes(result.stdout)
        (run_dir / (name + ".err")).write_bytes(result.stderr)
        commands.append({"名称": name, "命令": [str(value) for value in arguments], "退出码": result.returncode})
        if result.returncode != expected:
            raise RuntimeError(f"{name}未通过，退出码{result.returncode}；原始输出保存在本轮目录。")
        return result.stdout

    try:
        for architecture in ("arm64", "x86_64"):
            launch = ["arch", "-" + architecture]
            compiler = ["xcrun", "swiftc", "-target", architecture + "-apple-macos13.0", "-swift-version", "6", "-warnings-as-errors"]
            runtime = run_dir / ("运行时信任-" + architecture)
            receipt = run_dir / ("回执解析-" + architecture)
            run("运行时编译-" + architecture, compiler + ["Sources/HelperShared/PrivilegedMountProtocol.swift",
                "Sources/HelperShared/LegacyRuntime.swift", "Tests/Core/LegacyRuntimeTests.swift", "-o", runtime])
            run("缺参数拒绝-" + architecture, launch + [runtime], expected=64)
            run("缺前置拒绝-" + architecture, launch + [runtime, run_dir / "不存在Payload", helper], expected=66)
            runtime_result = json.loads(run("运行时运行-" + architecture, launch + [runtime, payload, helper]))
            if existing_prefix is None:
                writer = run_dir / ("真实C回执writer-" + architecture)
                prefix = run_dir / ("回执字节-" + architecture)
                run("C回执编译-" + architecture, ["xcrun", "clang", "-arch", architecture,
                    "-mmacosx-version-min=13.0", "-D_FILE_OFFSET_BITS=64", "-Wall", "-Wextra", "-Werror",
                    "-I", "ThirdParty/MacFUSEHeaders", "-I", "Sources/LegacyBackend",
                    "Sources/LegacyBackend/legacy_lease.c", "Tests/LegacyBackend/receipt_checks.c", "-o", writer])
                run("C回执生成-" + architecture, launch + [writer, prefix])
            else:
                prefix = Path(str(existing_prefix) + "-" + architecture)
            run("Swift回执编译-" + architecture, compiler + ["Sources/HelperShared/PrivilegedMountProtocol.swift",
                "Sources/HelperShared/LegacyReceipt.swift", "Tests/Core/LegacyReceiptTests.swift", "-o", receipt])
            run("回执缺参数拒绝-" + architecture, launch + [receipt], expected=64)
            receipt_result = json.loads(run("Swift解析C回执-" + architecture, launch + [receipt, prefix]))
            records.append({"架构": architecture, "运行时检查数": runtime_result["数量"], "回执检查数": receipt_result["数量"],
                            "回执前缀": str(prefix), "运行时结果": runtime_result["结果"], "回执结果": receipt_result["结果"]})
        report = {"结果": "通过", "分项": records, "命令": commands,
                  "范围": "官方制品签名、普通文件复制/ACL、真实C writer与Swift reader互通；macOS13部署目标编译与当前主机ARM/Rosetta执行。非旧系统、root缓存或系统挂载验收。"}
        (run_dir / "结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("验证通过；证据目录：" + str(run_dir))
    except Exception as error:
        (run_dir / "失败.json").write_text(json.dumps({"错误": str(error), "命令": commands}, ensure_ascii=False, indent=2) + "\n")
        raise SystemExit(str(error) + "\n证据目录：" + str(run_dir))


if __name__ == "__main__":
    main()
