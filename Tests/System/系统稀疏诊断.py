#!/usr/bin/env python3
"""复用安全镜像边界，仅收集一次稀疏写入的系统回调日志。"""

import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("regression", Path(__file__).with_name("系统镜像回归.py"))
test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test)
test.require(len(sys.argv) == 1 and os.geteuid() != 0, "只允许普通用户无参数运行")
inventory = json.loads(test.command([test.ROOT / "build/system-tests/扩展清单复核"]))
installed = Path.home() / "Applications/NTFSWriteFlow.app/Contents/Extensions/NTFSFileSystem.appex"
test.require(inventory.get("本应用扩展数") == 1 and inventory["扩展"][0]["启用"] is True
             and Path(inventory["扩展"][0]["路径"]).resolve() == installed.resolve(), "标准扩展必须唯一且启用")
test.RESULT["扩展可执行文件SHA256"] = test.digest(installed / "Contents/MacOS/NTFSFileSystem")
test.command(["/usr/bin/xcrun", "swiftc", "-framework", "IOKit",
              test.ROOT / "Tests/System/只读介质身份.swift", "-o", test.RUN / "只读介质身份"])
print(f"证据目录：{test.RUN}", flush=True)


def sparse(image):
    def check():
        path = image.mountpoint / "稀疏诊断.bin"
        with path.open("xb+", buffering=0) as stream:
            test.require(stream.write(b"HEAD") == 4, "头部写入失败")
            os.fsync(stream.fileno())
            stream.seek(64 * test.MIB + 7)
            test.require(stream.write(b"TAIL") == 4, "尾部写入失败")
            os.fsync(stream.fileno())
            stream.seek(32 * test.MIB)
            test.require(stream.read(4096) == bytes(4096), "空洞读零失败")
        st = path.stat()
        image.record["稀疏结果"] = {"逻辑": st.st_size, "分配": st.st_blocks * 512}
        test.save()
        test.require(st.st_size == 64 * test.MIB + 11 and st.st_blocks * 512 < 2 * test.MIB,
                     f"稀疏分配异常：{image.record['稀疏结果']}")
        return image.record["稀疏结果"]
    return test.case("系统稀疏最小诊断", check)


try:
    test.run_group("稀疏诊断", 256 * test.MIB, sparse)
finally:
    output = test.command(["/usr/bin/log", "show", "--last", "2m", "--style", "compact",
                           "--predicate", 'subsystem == "com.blteam.ntfsworkbench" AND category == "稀疏诊断"'])
    (test.RUN / "稀疏回调日志.txt").write_bytes(output)
    test.save()
sys.exit(0 if all(item["结果"] == "通过" for item in test.RESULT["用例"]) else 1)
