#!/usr/bin/env python3
"""真实NTFS普通镜像的ARM/Rosetta回调验证；不安装运行时，不执行系统挂载。"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    os.chdir(ROOT)
    if os.geteuid() == 0:
        raise SystemExit("测试必须由普通用户执行，不需要管理员权限。")
    output = ROOT / "build/0.3.0/旧后端"
    output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="真实回调-", dir=output))
    commands = []

    def run(name, args, expected=0):
        result = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (run_dir / (name + ".log")).write_bytes(result.stdout)
        commands.append({"名称": name, "命令": [str(x) for x in args], "退出码": result.returncode})
        if result.returncode != expected:
            raise RuntimeError(f"{name}未通过，退出码{result.returncode}，日志见本轮目录")
        return result.stdout

    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    try:
        records = []
        for arch in ("arm64", "x86_64"):
            run(f"构建-{arch}", ["bash", "script/build_legacy_backend.sh", arch])
            built = ROOT / "build/legacy" / arch
            engine = ROOT / "build/legacy" / f"engine-{arch}-13"
            compiler = ["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=13.0", "-D_FILE_OFFSET_BITS=64",
                        "-Wall", "-Wextra", "-Werror", "-I", "ThirdParty/MacFUSEHeaders",
                        "-I", "ThirdParty/NTFSBridge", "-I", "Sources/LegacyBackend"]
            libraries = [built / "legacy_device.o", built / "legacy_volume.o", built / "bridge.o",
                         engine / "libntfs-3g/.libs/libntfs-3g.a", "-framework", "CoreFoundation"]
            launch = ["arch", "-" + arch]
            test = run_dir / ("回调-" + arch)
            run(f"回调编译-{arch}", compiler + ["Tests/LegacyBackend/roundtrip.c"] + libraries + ["-o", test])
            image = run_dir / ("NTFS-" + arch + ".img")
            with image.open("xb") as stream:
                stream.truncate(64 * 1024 * 1024)
            run(f"格式化新建文件-{arch}", [ROOT / "build/engine/arm64/ntfsprogs/mkntfs", "-F", "-Q", "-L", "WF_LEGACY", image])
            run(f"真实写读回调-{arch}", launch + [test, "写入", image])
            digest = sha(image)
            run(f"只读重开拒写-{arch}", launch + [test, "只读", image])
            if sha(image) != digest:
                raise RuntimeError("只读回调改变整镜像摘要")
            data = run(f"独立工具复读-{arch}", [ROOT / "build/engine/arm64/ntfsprogs/ntfscat", image, "/中文目录/保存.bin"])
            if data != bytes(i % 251 for i in range(7000)):
                raise RuntimeError("独立工具复读内容不一致")
            device_test = run_dir / ("FD边界-" + arch)
            run(f"FD边界编译-{arch}", compiler + ["Tests/LegacyBackend/device_checks.c", "-o", device_test])
            run(f"FD边界运行-{arch}", launch + [device_test, run_dir / ("FD-" + arch + ".bin")])

            dirty = run_dir / ("脏卷-" + arch + ".img")
            shutil.copyfile(image, dirty)
            marker = run_dir / ("脏标记-" + arch)
            upstream = engine / "libntfs-3g/.libs/libntfs-3g.a"
            run(f"脏标记编译-{arch}", compiler + ["-DHAVE_CONFIG_H=1", "-I", engine, "-I", "ThirdParty/ntfs-3g/include",
                "Tests/LegacyBackend/mark_dirty.c", upstream, "-framework", "CoreFoundation", "-o", marker])
            run(f"脏标记写入-{arch}", launch + [marker, dirty])
            preflight = run_dir / ("预检-" + arch)
            run(f"预检编译-{arch}", compiler + ["Tests/LegacyBackend/preflight.c"] + libraries + ["-o", preflight])
            dirty_hash = sha(dirty)
            run(f"脏卷拒绝写-{arch}", launch + [preflight, "拒绝写", dirty])
            if sha(dirty) != dirty_hash:
                raise RuntimeError("拒绝的脏卷预检改变了镜像")
            run(f"脏卷只读恢复-{arch}", launch + [preflight, "只读", dirty])
            if sha(dirty) != dirty_hash:
                raise RuntimeError("脏卷只读恢复改变了镜像")
            options_probe = run_dir / ("固定选项-" + arch)
            run(f"固定选项编译-{arch}", compiler + ["Tests/LegacyBackend/options_checks.c", built / "legacy_options.o", "-o", options_probe])
            run(f"固定选项运行-{arch}", launch + [options_probe])
            lease_probe = run_dir / ("介质锁-" + arch)
            run(f"介质锁编译-{arch}", compiler + ["Tests/LegacyBackend/lease_checks.c", built / "legacy_lease.o", "-o", lease_probe])
            run(f"介质锁元数据-{arch}", launch + [lease_probe, "元数据", run_dir / ("元数据锁-" + arch)])
            lease_path = run_dir / ("继承锁-" + arch)
            control_read, control_write = os.pipe()
            status_read, status_write = os.pipe()
            launcher = """import os,sys,fcntl,subprocess
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
p=subprocess.Popen(sys.argv[4:],stdin=int(sys.argv[2]),stdout=fd,stderr=int(sys.argv[3]))
os.close(fd)
"""
            parent = subprocess.Popen(["python3", "-c", launcher, str(lease_path), str(control_read), str(status_write)] +
                launch + [str(lease_probe), "持有", str(lease_path)], pass_fds=(control_read, status_write))
            os.close(control_read)
            os.close(status_write)
            contender = None
            try:
                if parent.wait(timeout=5) != 0:
                    raise RuntimeError("租约父启动器失败")
                if not select.select([status_read], [], [], 5)[0] or os.read(status_read, 1024).decode().strip() != "已持锁":
                    raise RuntimeError("租约子进程未确认持有")
                contender = os.open(lease_path, os.O_RDWR)
                try:
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise RuntimeError("父进程退出后租约未由子进程持续持有")
                os.close(control_write)
                control_write = None
                if not select.select([status_read], [], [], 5)[0] or os.read(status_read, 1024) != b"":
                    raise RuntimeError("租约子进程未正常结束")
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                commands.append({"名称": "父退出子持锁-" + arch, "退出码": 0,
                                 "范围": "父进程真实退出、子进程关闭stdout后仍持有内部副本，子退出后可重新加锁"})
            finally:
                if control_write is not None:
                    os.close(control_write)
                os.close(status_read)
                if contender is not None:
                    os.close(contender)
            receipt_probe = run_dir / ("收尾回执-" + arch)
            run(f"收尾回执编译-{arch}", compiler + ["Tests/LegacyBackend/receipt_checks.c", built / "legacy_lease.o", "-o", receipt_probe])
            receipt_path = run_dir / ("回执字节-" + arch)
            run(f"收尾回执运行-{arch}", launch + [receipt_probe, receipt_path])
            for suffix, marker, status in [("pending", 0, 0), ("status0", 1, 0), ("status74", 1, 74), ("syncfail", 0, 0)]:
                data = Path(str(receipt_path) + "." + suffix).read_bytes()
                if not data or data[0] != marker:
                    raise RuntimeError("收尾回执提交标记不符")
                body = json.loads(data[1:].decode("utf-8"))
                if set(body) != {"version", "userID", "wholeMediaRegistryID", "token", "status"} or body != {
                    "version": 1, "userID": os.getuid(), "wholeMediaRegistryID": 9876543210,
                    "token": "11111111-2222-4333-8444-555555555555", "status": status}:
                    raise RuntimeError("收尾回执JSON字段或数值不符")
            commands.append({"名称": "实际回执UTF8与JSON-" + arch, "退出码": 0,
                             "范围": "真实C writer的pending/status0/status74/syncfail字节，独立JSON解码恰好五字段"})
            finish_probe = run_dir / ("真实末尾关闭-" + arch)
            run(f"末尾关闭编译-{arch}", compiler + ["Tests/LegacyBackend/finish_failure.c", built / "legacy_lease.o"] +
                libraries + ["-o", finish_probe])
            for mode, status in [("正常", 0), ("失败", 74)]:
                closing_image = run_dir / ("末尾关闭-" + mode + "-" + arch + ".img")
                closing_receipt = run_dir / ("末尾回执-" + mode + "-" + arch)
                shutil.copyfile(image, closing_image)
                run(f"实际末尾关闭-{mode}-{arch}", launch + [finish_probe, mode, closing_image, closing_receipt], status)
                data = closing_receipt.read_bytes()
                body = json.loads(data[1:].decode("utf-8"))
                if data[0] != 1 or body["status"] != status or body["wholeMediaRegistryID"] != 9876543210:
                    raise RuntimeError("真实末尾关闭结果未进入持久回执")
            commands.append({"名称": "实际关闭对照回执-" + arch, "退出码": 0,
                             "范围": "无资源限额的真实关闭0与进程本地RLIMIT_FSIZE造成的真实关闭失败，回执和退出码分别0/74"})
            legacy = built / "NTFSWriteFlowLegacy"
            run(f"CLI缺参数-{arch}", launch + [legacy], 64)
            token = str(uuid.uuid4()).upper()
            mount = f"/private/var/db/com.blteam.ntfsworkbench.mounts/{os.getuid()}/{token}/volume"
            runtime = mount[:-7] + "/runtime/libfuse.2.dylib"
            args = [legacy, "--mount", mount, "--uid", str(os.getuid()), "--bytes", "67108864",
                    "--readonly", "0", "--runtime", runtime, "--device", "disk9999s1", "--media-id", "12345"]
            run(f"CLI普通用户拒绝-{arch}", launch + args, 77)
            invalid = args.copy()
            invalid[8] = "2"
            run(f"CLI非法模式拒绝-{arch}", launch + invalid, 64)
            run(f"CLI缺少媒体租约拒绝-{arch}", launch + args[:-2], 64)
            for index, media in enumerate(["0", "-1", "0001", "18446744073709551616"]):
                invalid_media = args.copy()
                invalid_media[-1] = media
                run(f"CLI媒体标识拒绝-{arch}-{index}", launch + invalid_media, 64)
            metadata = run(f"最低系统-{arch}", ["xcrun", "vtool", "-show-build", legacy]).decode()
            if re.findall(r"\bminos\s+(\S+)", metadata) != ["13.0"]:
                raise RuntimeError("兼容前端最低系统不是13.0")
            slices = run(f"实际架构-{arch}", ["xcrun", "lipo", "-archs", legacy]).decode().split()
            if slices != [arch]:
                raise RuntimeError("兼容前端架构不匹配")
            records.append({"架构": arch, "实际运行": "原生" if arch == "arm64" else "Rosetta",
                            "只读全镜像SHA256": digest, "脏卷拒写及只读后SHA256": dirty_hash,
                            "生产前端SHA256": sha(legacy), "最低系统": "13.0"})
        report = {"结果": "通过", "命令": commands, "架构": records,
                  "范围": "真实NTFS普通文件镜像和实际FUSE操作表；raw扇区路径为普通文件模拟",
                  "未覆盖": ["真实macFUSE运行时与内核模块", "系统VFS挂载和Finder", "root管理员子程序",
                            "物理NTFS设备、TCC", "旧系统实机及Intel硬件"]}
        (run_dir / "结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"ARM与Rosetta真实NTFS回调、FD边界、脏卷预检和只读镜像不变全部通过：{run_dir}")
    except BaseException as error:
        (run_dir / "失败.json").write_text(json.dumps({"结果": "失败", "错误": str(error), "命令": commands}, ensure_ascii=False, indent=2))
        raise


if __name__ == "__main__":
    main()
