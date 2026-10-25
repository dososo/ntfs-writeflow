#!/usr/bin/env python3
"""以白名单生成可离线重建的开源候选源码包；不上传、不签名、不公证。"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = "7f0f841fc52cf719106c5c93bafe465004e36816"
ENGINE = ROOT / "ThirdParty/ntfs-3g"
TEXT_SUFFIXES = {".swift", ".m", ".h", ".c", ".sh", ".py", ".plist", ".entitlements", ".yml", ".json", ".md", ".m4"}
SOURCE_SUFFIXES = TEXT_SUFFIXES | {".icns", ".png", ".jpg", ".jpeg"}
SECRET_PATTERNS = [
    ("本机用户绝对路径", re.compile(rb"/" + rb"Users/[^/\s]+/")),
    ("私钥内容", re.compile(rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")),
    ("常见令牌字面值", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{25,}|sk-[A-Za-z0-9_-]{30,})")),
]


def command(*args):
    return subprocess.check_output(args, cwd=ROOT)


def collect():
    files = {}
    exact = ["LICENSE", "project.yml", ".gitmodules", ".gitignore", "README.md", "README.en.md", "第三方组件说明.md",
             "Configuration/App-Info.plist", "Configuration/App-Bridging-Header.h", "Configuration/FileSystem-Info.plist",
             "Configuration/FileSystem.entitlements", "Configuration/FileSystem-Bridging-Header.h",
             "Configuration/com.blteam.ntfsworkbench.mount-helper.plist",
             "设计/NTFS畅写图标原稿.png"]
    for name in exact:
        files[name] = ROOT / name
    for folder in ["Sources", "Tests", "script", "发布", "assets", "ThirdParty/NTFSBridge", "ThirdParty/FSKitAdapter"]:
        for path in (ROOT / folder).rglob("*"):
            relative = path.relative_to(ROOT)
            if any(part.endswith(".dSYM") or part in {"__pycache__", "产物", "结果", ".build", ".git", ".DS_Store"} for part in relative.parts):
                continue
            if path.is_symlink():
                raise SystemExit(f"白名单源码含符号链接，需审查：{relative}")
            if not path.is_file():
                continue
            # 历史机器结果不随开源源码分发。
            if path.name in {"验证结果.txt", ".gitignore", "backend_safety"}:
                continue
            if path.suffix not in SOURCE_SUFFIXES and path.name != "LICENSE":
                raise SystemExit(f"未登记的文件类型，停止打包：{relative}")
            files[str(relative)] = path
    # 根目录中英首页均为公开说明；与资源一起扫描并保留相对链接。
    payloads = {}
    for name, path in sorted(files.items()):
        data = path.read_bytes()
        if path.suffix in TEXT_SUFFIXES or path.name in {"LICENSE", ".gitmodules"}:
            for description, pattern in SECRET_PATTERNS:
                if pattern.search(data):
                    raise SystemExit(f"公开源码扫描拒绝：{name}：{description}")
        payloads[name] = (data, 0o755 if path.stat().st_mode & 0o111 else 0o644)
    if command("git", "-C", str(ENGINE), "rev-parse", "HEAD").decode().strip() != PIN:
        raise SystemExit("引擎提交不是锁定版本，停止打包。")
    if command("git", "-C", str(ENGINE), "status", "--porcelain").strip():
        raise SystemExit("引擎源码存在未提交改动，停止打包。")
    archive = command("git", "-C", str(ENGINE), "archive", "--format=tar", PIN)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for member in source.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or member.name.startswith("/") or ".." in Path(member.name).parts:
                raise SystemExit(f"上游归档含需审查的条目：{member.name}")
            payloads["ThirdParty/ntfs-3g/" + member.name] = (source.extractfile(member).read(), member.mode)
    # 上游源码也进行文本扫描；公共 Git bundle 在生成后另行核对固定 tip。
    for name, (data, _) in payloads.items():
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for description, pattern in SECRET_PATTERNS:
            if pattern.search(data):
                raise SystemExit(f"公开源码扫描拒绝：{name}：{description}")
    return payloads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="仅检查白名单和源码，不生成归档")
    args = parser.parse_args()
    payloads = collect()
    if args.check_only:
        print(f"白名单及文本扫描通过：{len(payloads)} 个源码、文档和资源文件；未扫描或打包工作区私密证据。")
        return
    output = ROOT / "build/release"
    output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="开源候选-", dir=output))
    bundle = run / "ntfs-3g.bundle"
    subprocess.run(["git", "-C", str(ENGINE), "bundle", "create", str(bundle), "HEAD"], check=True)
    subprocess.run(["git", "-C", str(ENGINE), "bundle", "verify", str(bundle)], check=True, stdout=subprocess.DEVNULL)
    payloads["ThirdParty/ntfs-3g.bundle"] = (bundle.read_bytes(), 0o644)
    manifest = {
        "说明": "仅本地开源候选，不代表完整产品验收、公证或公开发布通过。",
        "引擎固定提交": PIN,
        "文件": {name: {"SHA256": hashlib.sha256(data).hexdigest(), "权限": oct(mode), "字节数": len(data)}
                 for name, (data, mode) in sorted(payloads.items())},
    }
    manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
    payloads["源码清单.json"] = (manifest_data, 0o644)
    output_file = run / "NTFS-WriteFlow-源码候选.tar.gz"
    with output_file.open("xb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
                for name, (data, mode) in sorted(payloads.items()):
                    entry = tarfile.TarInfo("NTFS-WriteFlow/" + name)
                    entry.size = len(data)
                    entry.mode = mode
                    entry.mtime = 0
                    entry.uid = entry.gid = 0
                    entry.uname = entry.gname = ""
                    tar.addfile(entry, io.BytesIO(data))
    checksum = hashlib.sha256(output_file.read_bytes()).hexdigest()
    (run / "SHA256SUMS.txt").write_text(checksum + "  " + output_file.name + "\n")
    (run / "源码清单.json").write_bytes(manifest_data)
    print(f"候选源码包：{output_file}\nSHA-256：{checksum}\n未包含应用二进制；二进制须在同一源码冻结后另行构建、签名、验收。")


if __name__ == "__main__":
    main()
