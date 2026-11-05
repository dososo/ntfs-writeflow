"""完整应用候选工具的纯输入和静态元数据边界测试；不运行应用或服务。"""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent


class 应用候选测试(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("build_app_candidate", HERE / "build_app_candidate.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_属性候选只替换唯一已知实现(self):
        original = "前文\n" + self.module.OLD_PROPERTY + "\n后文"
        adapted = self.module.adapt_property(original)
        self.assertTrue(adapted.startswith("前文\n"))
        self.assertTrue(adapted.endswith("\n后文"))
        self.assertIn("private var openUnlinkEmulationEnabled", adapted)
        self.assertIn("@available(macOS 26.0, *)", adapted)
        self.assertIn("get { openUnlinkEmulationEnabled }", adapted)

    def test_未知属性和重复属性拒绝(self):
        for text in ("不同实现", self.module.OLD_PROPERTY * 2):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                self.module.adapt_property(text)

    def test_正确架构及最低版本通过(self):
        self.module.validate_macho_metadata("x86_64\n", "platform MACOS\n minos 26.0\n sdk 26.5", "x86_64", "26.0")

    def test_架构混入或最低版本错误拒绝(self):
        for arch, build in (("arm64", "platform MACOS\nminos 26.0"),
                            ("x86_64 arm64", "platform MACOS\nminos 26.0"),
                            ("x86_64", "platform MACOS\nminos 15.4"),
                            ("x86_64", "platform IOS\nminos 26.0"),
                            ("x86_64", "")):
            with self.subTest(arch=arch, build=build), self.assertRaises(RuntimeError):
                self.module.validate_macho_metadata(arch, build, "x86_64", "26.0")

    def test_读取助手嵌入配置而非仅相信工程设置(self):
        import plistlib
        raw = plistlib.dumps({"CFBundleIdentifier":"com.blteam.ntfsworkbench.mount-helper"})
        text = "\n".join(f"{0x1000 + n:016x} " + " ".join(f"{b:02x}" for b in raw[n:n+16]) for n in range(0,len(raw),16))
        self.assertEqual(self.module.decode_embedded_plist(text)["CFBundleIdentifier"], "com.blteam.ntfsworkbench.mount-helper")
        for invalid in ("", "不是十六进制", "0000000000001000 ff ff"):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                self.module.decode_embedded_plist(invalid)

    def test_完整包不允许任何外部开发机动态库(self):
        self.module.validate_dependencies("程序:\n /System/Library/Frameworks/FSKit.framework/FSKit (版本)\n /usr/lib/libSystem.B.dylib (版本)")
        for dependency in ("/opt/homebrew/lib/私有.dylib", "/Volumes/其他盘/私有.dylib", "@rpath/私有.dylib", "/usr/lib/../../私有.dylib"):
            with self.subTest(dependency=dependency), self.assertRaises(RuntimeError):
                self.module.validate_dependencies("程序:\n " + dependency + " (版本)")

    def test_只接受明确提交或HEAD(self):
        for value in ("HEAD", "27fe68e", "a" * 40):
            self.assertEqual(self.module.validate_revision(value), value)
        for value in ("--all", "main", "HEAD~1", "abc", ";命令"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module.validate_revision(value)

    def test_已知安全阻断不能混入无关错误(self):
        known = "file.swift:47:15: error: 'funmount' is only available in macOS 26.0 or newer"
        self.assertTrue(self.module.is_safety_block(65, known))
        self.assertFalse(self.module.is_safety_block(0, known))
        self.assertFalse(self.module.is_safety_block(65, "error: 引擎链接失败"))
        self.assertFalse(self.module.is_safety_block(65, known + "\nerror: 引擎链接失败"))

    def test_包标识和受限助手配置必须一致(self):
        app = {"CFBundleIdentifier":"com.blteam.ntfsworkbench", "LSMinimumSystemVersion":"26.0", "CFBundleExecutable":"NTFSWorkbench"}
        ext = {"CFBundleIdentifier":"com.blteam.ntfsworkbench.filesystem", "CFBundleExecutable":"NTFSFileSystem", "LSMinimumSystemVersion":"26.0",
               "EXAppExtensionAttributes":{"EXExtensionPointIdentifier":"com.apple.fskit.fsmodule", "FSShortName":"blntfs"}}
        daemon = {"Label":"com.blteam.ntfsworkbench.mount-helper", "BundleProgram":"Contents/Library/HelperTools/NTFSWriteFlowMountHelper",
                  "AssociatedBundleIdentifiers":["com.blteam.ntfsworkbench"], "MachServices":{"com.blteam.ntfsworkbench.mount-helper":True}}
        self.module.validate_bundle_metadata(app, ext, daemon)
        for target, key, value in ((app,"LSMinimumSystemVersion","15.4"), (ext,"CFBundleIdentifier","其他扩展"), (ext,"LSMinimumSystemVersion","15.4"),
                                   (daemon,"BundleProgram","/任意程序"), (daemon,"MachServices",{"其他服务":True})):
            previous = target[key]
            target[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.module.validate_bundle_metadata(app, ext, daemon)
            target[key] = previous


if __name__ == "__main__":
    unittest.main()
