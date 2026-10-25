"""本项目新增，2026-10-25，GPL-2.0：验证新建普通 NTFS 镜像的内容闭环。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RUN = Path(tempfile.mkdtemp(prefix="镜像闭环-", dir=ROOT / "验证/引擎"))
IMAGE = RUN / "测试卷.img"
TOOLS = ROOT / "build/engine/arm64/ntfsprogs"
ENV = dict(os.environ, LC_ALL="en_US.UTF-8")


def run(args, name, output=None):
    result = subprocess.run([str(a) for a in args], capture_output=True, env=ENV)
    (RUN / (name + ".日志.txt")).write_bytes(result.stderr if output else result.stdout + result.stderr)
    if output:
        output.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f"{name}失败，退出码 {result.returncode}；保留证据：{RUN}")
    print(name + "通过")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


with IMAGE.open("xb") as stream:
    stream.truncate(128 * 1024 * 1024)
run([TOOLS / "mkntfs", "-F", "-Q", "-s", "512", "-L", "TEST_ONLY", IMAGE], "格式化新建普通文件")

expected = bytearray((i * 29 + 7) % 251 for i in range(65573))
expected[4093:4190] = bytes([0xA5]) * 97
expected.extend(bytes([0x5A]) * 777)
del expected[51113:]
expected.extend(bytes(62000 - len(expected)))
(RUN / "预期最终内容.bin").write_bytes(expected)

run([ROOT / "build/engine/镜像闭环测试", "写入", IMAGE, RUN / "引擎读回.bin"], "引擎写入和重新打开")
before_ro = digest(IMAGE)
run([ROOT / "build/engine/镜像闭环测试", "只读", IMAGE, RUN / "只读读回.bin"], "只读拒写")
after_ro = digest(IMAGE)
assert before_ro == after_ro, "只读测试改变了镜像字节"

run([TOOLS / "ntfscat", IMAGE, "/中文资料/最终.bin"], "独立命令复读", RUN / "ntfscat读回.bin")
run([TOOLS / "ntfsls", "-l", "-p", "/中文资料", IMAGE], "独立目录检查")
digests = {name: digest(RUN / name) for name in ["预期最终内容.bin", "引擎读回.bin", "只读读回.bin", "ntfscat读回.bin"]}
assert len(set(digests.values())) == 1, f"最终内容不一致：{digests}"
report = {
    "结果": "通过",
    "引擎提交": "7f0f841fc52cf719106c5c93bafe465004e36816",
    "桥接提交": "b52f9bea006bafad032455533e499bccd7e605c8",
    "镜像": str(IMAGE),
    "内容哈希": digests,
    "只读前后镜像哈希": [before_ro, after_ro],
    "边界": "仅普通文件上的离线引擎验证；ntfscat 绕过桥接但仍使用同一 NTFS-3G 引擎，不是独立文件系统实现；未验证 FSKit、真实磁盘、Windows 或异常掉电。",
}
(RUN / "结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(ROOT / "验证/引擎/最近结果路径.txt").write_text(str(RUN) + "\n")
print("内容与只读镜像哈希校验全部通过，证据：" + str(RUN))
