"""离线兼容准备工具的输入边界；只创建并保留自有普通文件。"""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class 准备边界测试(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("prepare_candidate", HERE / "prepare_candidate.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="writeflow-兼容准备测试-")).resolve()

    def test_合法固定头文件缓存(self):
        path = self.directory / "fuse.h"
        path.write_bytes("固定内容".encode())
        import hashlib
        pins = {"fuse.h": hashlib.sha256(path.read_bytes()).hexdigest()}
        self.module.verify_headers(self.directory, pins)

    def test_篡改缓存拒绝(self):
        (self.directory / "fuse.h").write_text("篡改")
        with self.assertRaisesRegex(RuntimeError, "校验"):
            self.module.verify_headers(self.directory, {"fuse.h": "0" * 64})

    def test_缺失许可证拒绝(self):
        with self.assertRaisesRegex(RuntimeError, "普通文件"):
            self.module.verify_headers(self.directory, {"COPYING": "0" * 64})

    def test_符号链接拒绝(self):
        path = self.directory / "实际文件"
        path.write_text("内容")
        (self.directory / "fuse.h").symlink_to(path)
        with self.assertRaisesRegex(RuntimeError, "普通文件"):
            self.module.verify_headers(self.directory, {"fuse.h": "0" * 64})

    def test_命名管道拒绝而不阻塞(self):
        import os
        os.mkfifo(self.directory / "fuse.h")
        with self.assertRaisesRegex(RuntimeError, "普通文件"):
            self.module.verify_headers(self.directory, {"fuse.h": "0" * 64})

    def test_输出必须是构建目录内全新目录(self):
        root = self.directory
        (root / "build").mkdir()
        self.assertEqual(self.module.validate_output(root / "build/新候选", root), root / "build/新候选")
        (root / "build/已有候选").mkdir()
        for target in (root / "build", root / "build/已有候选", root / "外部候选", root / "build/../逃逸候选"):
            with self.subTest(target=target), self.assertRaises(RuntimeError):
                self.module.validate_output(target, root)

    def test_输出路径中符号链接拒绝(self):
        (self.directory / "build").mkdir()
        (self.directory / "实际目录").mkdir()
        (self.directory / "build/链接").symlink_to(self.directory / "实际目录")
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            self.module.validate_output(self.directory / "build/链接/新候选", self.directory)

    def test_归档拒绝上级路径与链接(self):
        for name, kind in (("../外部", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("/绝对", tarfile.REGTYPE)):
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w") as archive:
                item = tarfile.TarInfo(name)
                item.type = kind
                archive.addfile(item)
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                self.module.extract_source(data.getvalue(), self.directory)

    def test_归档接受普通文件(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            item = tarfile.TarInfo("src/固定.c")
            item.size = 3
            archive.addfile(item, io.BytesIO(b"abc"))
        self.module.extract_source(data.getvalue(), self.directory)
        self.assertEqual((self.directory / "src/固定.c").read_bytes(), b"abc")

    def test_前端接受显式准备目录(self):
        import subprocess
        result = subprocess.run(["python3", str(HERE / "build_frontend_candidate.py"), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--work-dir", result.stdout)

    def test_准备产物篡改拒绝(self):
        path = self.directory / "engine-arm64-13/config.h"
        path.parent.mkdir()
        path.write_text("篡改")
        import json
        (self.directory / "离线准备结果.json").write_text(json.dumps({"引擎提交": self.module.PIN, "官方头文件提交": self.module.HEADERS_PIN, "产物": {f"engine-{arch}-13/{name}": "0" * 64 for arch in ("arm64", "x86_64") for name in ("config.h", "libntfs-3g/.libs/libntfs-3g.a")}}))
        with self.assertRaisesRegex(RuntimeError, "产物校验"):
            self.module.verify_prepared(self.directory)

    def test_缺失双架构产物记录拒绝(self):
        import json
        (self.directory / "离线准备结果.json").write_text(json.dumps({"引擎提交": self.module.PIN, "官方头文件提交": self.module.HEADERS_PIN, "产物": {}}))
        with self.assertRaisesRegex(RuntimeError, "缺失"):
            self.module.verify_prepared(self.directory)

    def test_固定源码错误提交拒绝(self):
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.directory)], check=True)
        (self.directory / "源.c").write_text("固定源")
        subprocess.run(["git", "-C", str(self.directory), "add", "源.c"], check=True)
        subprocess.run(["git", "-C", str(self.directory), "-c", "user.name=测试", "-c", "user.email=test@example.invalid", "commit", "-qm", "固定测试源"], check=True)
        with self.assertRaisesRegex(RuntimeError, "固定提交"):
            self.module.verify_source(self.directory)

    def test_固定源码工作区或暂存区改动拒绝(self):
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.directory)], check=True)
        path = self.directory / "源.c"
        path.write_text("固定源")
        subprocess.run(["git", "-C", str(self.directory), "add", "源.c"], check=True)
        subprocess.run(["git", "-C", str(self.directory), "-c", "user.name=测试", "-c", "user.email=test@example.invalid", "commit", "-qm", "固定测试源"], check=True)
        pin = subprocess.check_output(["git", "-C", str(self.directory), "rev-parse", "HEAD"], text=True).strip()
        self.module.verify_source(self.directory, pin)
        path.write_text("改动")
        with self.assertRaises(subprocess.CalledProcessError):
            self.module.verify_source(self.directory, pin)
        subprocess.run(["git", "-C", str(self.directory), "add", "源.c"], check=True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.module.verify_source(self.directory, pin)

    def test_两个架构独立配置且不引用产品引擎(self):
        for arch in ("arm64", "x86_64"):
            command, env = self.module.configure_plan(arch, "arm64", "/固定SDK")
            self.assertIn("-arch " + arch, env["CFLAGS"])
            self.assertIn("-mmacosx-version-min=13.0", env["CFLAGS"])
            self.assertIn("--disable-shared", command)
            self.assertIn("--disable-ntfs-3g", command)
            self.assertEqual(command[0], "../source/configure")
            self.assertNotIn("build/engine", str(command) + str(env))
            self.assertEqual(any(x.startswith("--host=") for x in command), arch != "arm64")


if __name__ == "__main__":
    unittest.main()
