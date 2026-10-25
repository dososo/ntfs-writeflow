#!/usr/bin/env python3
"""只创建本轮镜像，不接受设备路径；所有挂载和分离都先核对镜像映射。"""

import concurrent.futures
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback


ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3
MIB = 1024**2
RESERVE = 20 * GIB
OUT = Path(__file__).resolve().parent / "结果"
OUT.mkdir(exist_ok=True)
RUN = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=OUT))
RESULT = {"开始": time.strftime("%Y-%m-%d %H:%M:%S%z"), "用例": [], "镜像": []}
COMMAND_NUMBER = 0


class CommandFailure(RuntimeError):
    def __init__(self, program, returncode, message):
        super().__init__(message)
        self.program = str(program)
        self.returncode = returncode


def save():
    (RUN / "结果.json").write_text(json.dumps(RESULT, ensure_ascii=False, indent=2) + "\n")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def command(args, timeout=120):
    global COMMAND_NUMBER
    COMMAND_NUMBER += 1
    completed = subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout)
    prefix = RUN / f"命令-{COMMAND_NUMBER:03d}"
    prefix.with_suffix(".json").write_text(json.dumps({"参数": [str(x) for x in args],
        "退出码": completed.returncode}, ensure_ascii=False, indent=2))
    prefix.with_suffix(".out").write_bytes(completed.stdout)
    prefix.with_suffix(".err").write_bytes(completed.stderr)
    if completed.returncode:
        raise CommandFailure(args[0], completed.returncode,
                             f"命令失败（{completed.returncode}）：{args[0]}；" +
                             completed.stderr.decode(errors="replace")[-1500:])
    return completed.stdout


def case(name, body):
    print(f"开始：{name}", flush=True)
    start = time.monotonic()
    item = {"名称": name}
    try:
        item["证据"] = body()
        item["结果"] = "通过"
    except Exception as error:
        item.update({"结果": "失败", "错误": str(error), "回溯": traceback.format_exc()})
    item["秒"] = round(time.monotonic() - start, 3)
    RESULT["用例"].append(item)
    save()
    print(f"{item['结果']}：{name}（{item['秒']} 秒）", flush=True)
    return item["结果"] == "通过"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while data := stream.read(8 * MIB):
            value.update(data)
    return value.hexdigest()


def write_file(path, data):
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


class Image:
    def __init__(self, name, size):
        require(shutil.disk_usage("/private/tmp").free > size + RESERVE,
                "宿主盘余量不足：必须保留 20 GiB，未创建镜像")
        self.directory = Path(tempfile.mkdtemp(prefix="blntfs-回归-", dir="/private/tmp"))
        self.path = self.directory / "全新测试卷.img"
        self.mountpoint = self.directory / "挂载点"
        self.mountpoint.mkdir()
        self.size = size
        self.device = None
        self.record = {"组": name, "镜像": str(self.path), "容量": size,
                       "挂载点": str(self.mountpoint), "已清理": False}
        RESULT["镜像"].append(self.record)
        save()
        with self.path.open("xb") as stream:
            stream.truncate(size)
        command([ROOT / "build/engine/arm64/ntfsprogs/mkntfs", "-F", "-Q",
                 "-L", "BLNTFS_REGRESSION", self.path])

    def mapping(self):
        images = plistlib.loads(command(["/usr/bin/hdiutil", "info", "-plist"]))["images"]
        return [entry for entry in images if entry.get("image-path") and
                Path(entry["image-path"]).resolve() == self.path.resolve()]

    def verify(self):
        require(self.device is not None, "没有本轮设备身份")
        entries = self.mapping()
        require(len(entries) == 1, "镜像映射不唯一；拒绝操作设备")
        devices = [item.get("dev-entry") for item in entries[0].get("system-entities", [])]
        require(devices == [self.device], "设备映射已变化；拒绝操作设备")
        info = plistlib.loads(command(["/usr/sbin/diskutil", "info", "-plist", self.device]))
        require(info.get("VirtualOrPhysical") == "Virtual" and info.get("BusProtocol") == "Disk Image"
                and info.get("WholeDisk") and info.get("IOKitSize") == self.size
                and info.get("DeviceNode") == self.device, "设备不是预期容量的本轮虚拟整盘")
        return info

    def attach(self):
        require(not self.mapping(), "本轮镜像已经附加")
        data = plistlib.loads(command(["/usr/bin/hdiutil", "attach", "-nomount", "-nobrowse",
                                      "-readwrite", "-plist", self.path]))
        entities = data.get("system-entities", [])
        require(len(entities) == 1, "预期无分区镜像返回一个设备；保留现场")
        device = entities[0].get("dev-entry", "")
        require(re.fullmatch(r"/dev/disk[0-9]+", device), "拒绝非整盘设备名")
        self.device = device
        self.record["设备"] = device
        self.record["附加介质可写"] = self.verify().get("WritableMedia")
        require(self.record["附加介质可写"] is True, "测试必须使用可写附加介质")
        save()

    def mounted_line(self):
        lines = command(["/sbin/mount"]).decode().splitlines()
        matching = [line for line in lines if f" on {self.mountpoint} (" in line]
        require(len(matching) <= 1, "挂载点不唯一")
        if matching:
            require(matching[0].startswith(f"{self.device} on {self.mountpoint} (blntfs,")
                    and "fskit" in matching[0], "挂载点不是本轮设备的 blntfs，拒绝继续")
        foreign = [line for line in lines if line.startswith(f"{self.device} on ") and line not in matching]
        require(not foreign, "本轮设备被其他位置挂载，拒绝继续或自动分离")
        return matching[0] if matching else None

    def mount(self, readonly=False):
        self.verify()
        require(self.mounted_line() is None, "挂载前设备已经挂载")
        identity = int(command([RUN / "只读介质身份", self.device.removeprefix("/dev/")]))
        require(identity > 0, "未取得虚拟介质注册身份")
        self.verify()
        command(["/sbin/mount", "-F", "-t", "blntfs", "-o",
                 ("rdonly" if readonly else "rw") + f",nosuid,nodev,nobrowse,writeflow-media-id={identity}",
                 self.device, self.mountpoint])
        line = self.mounted_line()
        require(line is not None and (("read-only" in line) == readonly), "实际挂载模式不符")
        self.record.setdefault("挂载记录", []).append(line)
        save()

    def close(self):
        if self.device:
            self.verify()
            if self.mounted_line():
                command(["/sbin/umount", self.mountpoint])
                require(self.mounted_line() is None, "正常卸载未完成")
            self.verify()
            command(["/usr/bin/hdiutil", "detach", self.device])
            require(not self.mapping(), "分离后仍有镜像映射")
            self.device = None
        self.record["已卸载并分离"] = True
        save()

    def finish(self, passed):
        self.close()
        if passed:
            # 只删除本轮创建且已确认分离的一个镜像，不递归删除目录。
            self.path.unlink()
            self.record["已清理"] = True
        else:
            self.record["保留失败镜像"] = True
        save()


def run_group(name, size, body, mount_first=True):
    image = None
    passed = False
    try:
        image = Image(name, size)
        image.attach()
        if mount_first:
            image.mount()
        passed = body(image)
    except Exception as error:
        RESULT["用例"].append({"名称": name + "准备或清理", "结果": "失败", "错误": str(error),
                              "回溯": traceback.format_exc()})
        print(f"失败：{name}：{error}", flush=True)
    finally:
        if image:
            try:
                image.finish(passed)
            except Exception as error:
                RESULT["用例"].append({"名称": name + "清理", "结果": "失败", "错误": str(error)})
                save()
                # 清理失败可能还持有设备，不继续制造新的挂载。
                raise
        save()


def semantics(image):
    root = image.mountpoint
    passed = []

    def concurrent_files():
        def worker(index):
            folder = root / f"并发-{index}"
            folder.mkdir()
            for number in range(40):
                data = hashlib.sha256(f"{index}:{number}".encode()).digest() * 1025
                first = folder / f"{number}.初始"
                last = folder / f"{number}.完成"
                write_file(first, data)
                first.rename(last)
                require(last.read_bytes() == data, "并发文件内容不一致")
            require(len(list(folder.iterdir())) == 40, "并发目录枚举数不符")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(worker, range(8)))
        return {"线程": 8, "文件": 320, "每文件字节": 32800}

    def rename_open():
        old = root / "覆盖目标.txt"
        new = root / "覆盖来源.txt"
        write_file(old, b"old-data")
        write_file(new, b"new-data-123")
        with old.open("r+b") as handle:
            os.replace(new, old)
            require(handle.read() == b"old-data", "rename覆盖破坏旧打开句柄")
            require(old.read_bytes() == b"new-data-123", "rename覆盖后路径不是新内容")
            old.unlink()
            handle.seek(0)
            handle.write(b"updated!")
            handle.flush()
            os.fsync(handle.fileno())
            handle.seek(0)
            require(handle.read() == b"updated!", "删除后旧句柄读写不一致")
        require(not old.exists() and not new.exists(), "关闭后已删除名称重新出现")
        return {"覆盖时旧句柄保留": True, "删除后句柄读写同步": True}

    def sparse():
        path = root / "稀疏文件.bin"
        with path.open("xb+") as stream:
            stream.write(b"HEAD")
            stream.seek(64 * MIB + 7)
            stream.write(b"TAIL")
            stream.flush()
            os.fsync(stream.fileno())
            for offset in (4093, 32 * MIB, 64 * MIB - 4096):
                stream.seek(offset)
                require(stream.read(4096) == bytes(4096), "稀疏空洞并非零")
        st = path.stat()
        require(st.st_size == 64 * MIB + 11, "稀疏逻辑长度不符")
        require(st.st_blocks * 512 < 2 * MIB, f"稀疏文件实际分配过大：逻辑{st.st_size}，分配{st.st_blocks * 512}")
        return {"逻辑字节": st.st_size, "分配字节": st.st_blocks * 512}

    def names_xattr():
        names = ["长" * 240 + ".txt", "中文🌕组合e\u0301.txt", "空 格'引号.txt"]
        for index, name in enumerate(names):
            path = root / name
            data = f"内容-{index}".encode()
            write_file(path, data)
            require(path.read_bytes() == data, "Unicode名称读写不一致")
        path = root / names[1]
        value = bytes(range(256)) * 17
        command(["/usr/bin/xattr", "-wx", "com.blteam.regression", value.hex(), path])
        actual = command(["/usr/bin/xattr", "-px", "com.blteam.regression", path])
        require(bytes.fromhex(actual.decode()) == value, "扩展属性内容不一致")
        return {"名称": names, "扩展属性字节": len(value)}

    for name, function in [("并发小文件", concurrent_files), ("rename覆盖与打开后删除", rename_open),
                           ("稀疏空洞与分配量", sparse), ("长名称Unicode与扩展属性", names_xattr)]:
        passed.append(case(name, function))
    return all(passed)


def identity_guard(image):
    def check():
        image.verify()
        baseline = digest(image.path)
        identity = int(command([RUN / "只读介质身份", image.device.removeprefix("/dev/")]))
        image.record["错误身份请求前哈希"] = baseline
        image.record["错误身份请求ID"] = identity + 1
        save()
        image.verify()
        rejected = None
        try:
            command(["/sbin/mount", "-F", "-t", "blntfs", "-o",
                     f"rw,nosuid,nodev,nobrowse,writeflow-media-id={identity + 1}",
                     image.device, image.mountpoint])
        except RuntimeError as error:
            rejected = str(error)
        require(rejected is not None and image.mounted_line() is None, "错误介质身份未被拒绝")
        direct_detach = "通过"
        try:
            image.close()
        except CommandFailure as error:
            if error.program != "/usr/bin/hdiutil" or error.returncode != errno.EBUSY:
                raise
            direct_detach = "未通过：资源忙；仅自有镜像只读重新加载恢复"
            image.record["直接分离限制"] = str(error)
            RESULT.setdefault("未通过的附加检查", []).append({
                "名称": "错误身份拒绝后直接分离", "结果": "未通过", "错误": str(error)})
            # 此恢复只适用于本轮自有且已核验映射的镜像，产品不能自动替换错误身份。
            image.verify()
            image.mountpoint = image.directory / "只读恢复挂载点"
            image.mountpoint.mkdir()
            image.record["挂载点"] = str(image.mountpoint)
            image.mount(readonly=True)
            image.close()
        after = digest(image.path)
        require(after == baseline, "错误身份请求改变了镜像字节")
        # 失败后使用新的挂载点，避免系统保留的失败状态影响有效身份的对照。
        image.mountpoint = image.directory / "正确身份挂载点"
        image.mountpoint.mkdir()
        image.record["挂载点"] = str(image.mountpoint)
        image.attach()
        image.mount()
        path = image.mountpoint / "正确身份写入.txt"
        write_file(path, b"verified-media-identity")
        require(path.read_bytes() == b"verified-media-identity", "正确身份写入复读失败")
        return {"错误ID": identity + 1, "拒绝结果": rejected, "前哈希": baseline,
                "后哈希": after, "正确ID挂载读写": True, "直接分离": direct_detach}
    return case("错误介质身份拒绝且不改镜像及正确身份对照", check)


def readonly(image):
    data = "只读策略验收".encode()
    write_file(image.mountpoint / "已有文件.txt", data)
    image.close()
    before = digest(image.path)
    image.attach()
    require(image.verify().get("WritableMedia") is True, "只读验证底层不是可写介质")
    image.mount(readonly=True)

    def check():
        failures = {}
        for name, path, flags in [("创建", image.mountpoint / "拒绝创建.txt", os.O_CREAT | os.O_WRONLY),
                                 ("截断已有", image.mountpoint / "已有文件.txt", os.O_TRUNC | os.O_WRONLY)]:
            try:
                fd = os.open(path, flags, 0o600)
            except OSError as error:
                failures[name] = error.errno
                require(error.errno == errno.EROFS, "只读请求未返回EROFS")
            else:
                os.close(fd)
                raise AssertionError("只读挂载允许修改")
        require((image.mountpoint / "已有文件.txt").read_bytes() == data, "只读内容改变")
        image.close()
        after = digest(image.path)
        require(before == after, "可写介质只读挂载改变了镜像字节")
        return {"底层可写": True, "错误码": failures, "前哈希": before, "后哈希": after}

    return case("可写介质上的只读策略与完整镜像哈希", check)


def disk_full(image):
    def check():
        anchor = image.mountpoint / "保留记录.txt"
        content = b"disk-full-anchor-unchanged"
        write_file(anchor, content)
        filler = image.mountpoint / "填满文件.bin"
        fd = os.open(filler, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        count = 0
        observed = None
        try:
            while count <= image.size:
                require(shutil.disk_usage("/private/tmp").free > RESERVE, "宿主余量触底，停止小镜像写入")
                try:
                    count += os.write(fd, bytes([0xA7]) * MIB)
                    os.fsync(fd)
                except OSError as error:
                    observed = error.errno
                    break
        finally:
            os.close(fd)
        require(observed == errno.ENOSPC, f"容量耗尽应返回ENOSPC，实际{observed}")
        require(anchor.read_bytes() == content, "磁盘满破坏已有文件")
        filler.unlink()
        write_file(image.mountpoint / "回收后写入.bin", bytes([0x3D]) * MIB)
        image.close()
        image.attach()
        image.mount()
        require((image.mountpoint / "回收后写入.bin").read_bytes() == bytes([0x3D]) * MIB,
                "磁盘满恢复文件重挂载后损坏")
        require(anchor.read_bytes() == content, "保留记录重挂载后损坏")
        return {"容量": image.size, "成功写入字节": count, "容量耗尽错误码": observed, "回收后重挂载": True}

    return case("小镜像磁盘满与删除后恢复", check)


def large(image):
    def check():
        path = image.mountpoint / "超过4GiB.bin"
        total = 4 * GIB + 17 * MIB + 123
        expected = hashlib.sha256()
        written = 0
        with path.open("xb", buffering=0) as stream:
            while written < total:
                if written % (256 * MIB) == 0:
                    require(shutil.disk_usage("/private/tmp").free > RESERVE, "宿主余量触底，停止大文件测试")
                    print(f"大文件写入：{written // MIB} / {total // MIB} MiB", flush=True)
                # 每块内容包含偏移身份，避免越过4GiB后地址回绕仍被重复数据掩盖。
                seed = hashlib.sha256(str(written).encode()).digest()
                block = seed * (4 * MIB // len(seed))
                data = block[:min(len(block), total - written)]
                offset = 0
                while offset < len(data):
                    count = stream.write(data[offset:])
                    require(count is not None and count > 0, "大文件写入未前进")
                    offset += count
                expected.update(data)
                written += len(data)
            os.fsync(stream.fileno())
        require(path.stat().st_size == total, "大文件长度不符")
        require(digest(path) == expected.hexdigest(), "大文件首次复读哈希不符")
        image.close()
        image.attach()
        image.mount(readonly=True)
        require(path.stat().st_size == total and digest(path) == expected.hexdigest(),
                "大文件卸载重挂载后哈希不符")
        return {"实际字节": total, "SHA256": expected.hexdigest(), "卸载重挂载全量复读": True}

    return case("超过4GiB实际数据写入与重挂载全量复读", check)


def main():
    require(len(sys.argv) == 1, "不接受任何参数或设备路径")
    require(os.geteuid() != 0, "请以已启用扩展的普通用户运行，禁止sudo")
    print(f"证据目录：{RUN}", flush=True)
    preflight = json.loads(command([ROOT / "build/system-tests/扩展清单复核"]))
    require(preflight.get("本应用扩展数") == 1 and preflight["扩展"][0]["启用"] is True,
            "需要唯一且已启用的正式扩展")
    installed = Path.home() / "Applications/NTFSWriteFlow.app/Contents/Extensions/NTFSFileSystem.appex"
    require(Path(preflight["扩展"][0]["路径"]).resolve() == installed.resolve(), "启用的扩展不是标准安装版")
    RESULT["扩展"] = preflight
    command(["/usr/bin/codesign", "-dvvv", installed])
    RESULT["扩展可执行文件SHA256"] = digest(installed / "Contents/MacOS/NTFSFileSystem")
    command(["/usr/bin/xcrun", "swiftc", "-framework", "IOKit",
             ROOT / "Tests/System/只读介质身份.swift", "-o", RUN / "只读介质身份"])
    RESULT["宿主开始余量"] = shutil.disk_usage("/private/tmp").free
    save()
    run_group("介质身份", 64 * MIB, identity_guard, mount_first=False)
    run_group("文件语义", 256 * MIB, semantics)
    run_group("可写介质只读", 128 * MIB, readonly)
    run_group("小镜像容量耗尽", 64 * MIB, disk_full)
    run_group("大文件", 6 * GIB, large)
    RESULT["结束"] = time.strftime("%Y-%m-%d %H:%M:%S%z")
    RESULT["结果"] = "通过" if all(x["结果"] == "通过" for x in RESULT["用例"]) else "失败"
    if RESULT["结果"] == "通过" and RESULT.get("未通过的附加检查"):
        RESULT["结果"] = "功能用例通过，附加检查未通过"
    RESULT["边界"] = "仅全新镜像；不覆盖真实介质、断电、拔插、睡眠唤醒或Windows独立实现复读。"
    save()
    print(f"总结果：{RESULT['结果']}；{RUN / '结果.json'}", flush=True)
    return 0 if RESULT["结果"] == "通过" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        RESULT.update({"结果": "中止", "中止原因": str(error), "回溯": traceback.format_exc()})
        save()
        print(f"中止：{error}；请检查 {RUN / '结果.json'}", file=sys.stderr)
        sys.exit(2)
