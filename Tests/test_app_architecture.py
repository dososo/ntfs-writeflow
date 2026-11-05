"""用真实 Mach-O 切片验证发行包架构和最低系统门禁；保留本轮产物。"""
import os
import importlib.util
import json
import sys
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / 'script/check_app_architecture.py'


class AppArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        output = ROOT / 'build/0.3.0/Intel开发'
        output.mkdir(parents=True, exist_ok=True)
        cls.work = Path(tempfile.mkdtemp(prefix='架构门禁测试-', dir=output))
        source = cls.work / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        cls.thin = {}
        for arch in ['arm64', 'x86_64']:
            for minimum in ['13.0', '15.4', '26.0']:
                path = cls.work / f'{arch}-{minimum}'
                subprocess.run(['xcrun', 'clang', '-arch', arch, f'-mmacosx-version-min={minimum}',
                                str(source), '-o', str(path)], check=True, capture_output=True)
                cls.thin[arch, minimum] = path
        cls.fat = {}
        for minimum in ['13.0', '15.4', '26.0']:
            path = cls.work / f'universal-{minimum}'
            subprocess.run(['xcrun', 'lipo', '-create', str(cls.thin['arm64', minimum]),
                            str(cls.thin['x86_64', minimum]), '-output', str(path)], check=True)
            cls.fat[minimum] = path
        cls.universal = cls.fat['26.0']

    def app(self, architecture='universal', minimum='26.0', extension_minimum='26.0'):
        app = Path(tempfile.mkdtemp(prefix='包-', dir=self.work)) / '测试.app'
        executable = self.fat[minimum] if architecture == 'universal' else self.thin[architecture, minimum]
        for relative, name, target_minimum in [('Contents', '测试宿主', minimum),
                               ('Contents/Extensions/NTFSFileSystem.appex/Contents', '测试扩展', extension_minimum)]:
            contents = app / relative
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': name, 'LSMinimumSystemVersion': target_minimum}))
            target = self.fat[target_minimum] if architecture == 'universal' else self.thin[architecture, target_minimum]
            shutil.copy2(target, contents / 'MacOS' / name)
        helper = app / 'Contents/Library/HelperTools/NTFSWriteFlowMountHelper'
        helper.parent.mkdir(parents=True)
        shutil.copy2(executable, helper)
        shutil.copy2(executable, helper.with_name('NTFSWriteFlowLegacy'))
        return app

    def check(self, app, arch='universal', minimum='26.0', extension_minimum='26.0'):
        arguments = ['python3', str(GATE), '--app', str(app), '--arch', arch]
        if minimum:
            arguments += ['--minimum-system', minimum]
        if extension_minimum:
            arguments += ['--extension-minimum-system', extension_minimum]
        return subprocess.run(arguments, capture_output=True, text=True)

    def test_default_release_minimums_match_current_host_and_extension(self):
        app = self.app(minimum='13.0', extension_minimum='15.4')
        result = subprocess.run(['python3', str(GATE), '--app', str(app)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_universal_app_passes(self):
        result = self.check(self.app())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_single_architecture_passes(self):
        for arch in ['arm64', 'x86_64']:
            result = self.check(self.app(arch), arch)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_helper_missing_intel_slice_is_rejected(self):
        app = self.app()
        shutil.copy2(self.thin['arm64', '26.0'], app / 'Contents/Library/HelperTools/NTFSWriteFlowMountHelper')
        result = self.check(app)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('架构', result.stderr)

    def test_single_architecture_mode_rejects_mixed_bundle(self):
        result = self.check(self.app(), 'arm64')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('架构', result.stderr)

    def test_extension_wrong_minimum_is_rejected(self):
        app = self.app('x86_64')
        shutil.copy2(self.thin['x86_64', '15.4'],
                     app / 'Contents/Extensions/NTFSFileSystem.appex/Contents/MacOS/测试扩展')
        result = self.check(app, 'x86_64')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('最低系统', result.stderr)

    def test_plist_wrong_minimum_is_rejected(self):
        app = self.app()
        path = app / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['LSMinimumSystemVersion'] = '15.4'
        path.write_bytes(plistlib.dumps(info))
        result = self.check(app)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('最低系统', result.stderr)

    def test_extra_debug_library_missing_slice_is_rejected(self):
        app = self.app()
        shutil.copy2(self.thin['arm64', '26.0'], app / 'Contents/MacOS/测试宿主.debug.dylib')
        result = self.check(app)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('架构', result.stderr)

    def test_explicit_different_host_and_extension_minimums_pass(self):
        app = self.app(minimum='13.0', extension_minimum='15.4')
        result = self.check(app, minimum='13.0', extension_minimum='15.4')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.check(app).returncode, 1)  # 不从待验包自动推导预期。

    def test_legacy_helper_is_checked_against_host_minimum(self):
        app = self.app('x86_64', '13.0', '15.4')
        legacy = app / 'Contents/Library/HelperTools/NTFSWriteFlowLegacy'
        shutil.copy2(self.thin['x86_64', '13.0'], legacy)
        result = self.check(app, 'x86_64', '13.0', '15.4')
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copy2(self.thin['x86_64', '26.0'], legacy)
        result = self.check(app, 'x86_64', '13.0', '15.4')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('最低系统', result.stderr)

    def test_legacy_helper_missing_slice_is_rejected(self):
        app = self.app(minimum='13.0', extension_minimum='15.4')
        shutil.copy2(self.thin['arm64', '13.0'], app / 'Contents/Library/HelperTools/NTFSWriteFlowLegacy')
        result = self.check(app, minimum='13.0', extension_minimum='15.4')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('架构', result.stderr)

    def test_missing_legacy_is_rejected_by_release_cli(self):
        app = self.app()
        (app / 'Contents/Library/HelperTools/NTFSWriteFlowLegacy').unlink()
        result = self.check(app)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('兼容前端', result.stderr)
        spec = importlib.util.spec_from_file_location('architecture_gate', GATE)
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        records = gate.inspect_app(app, 'universal', '26.0', '26.0', require_legacy=False)
        self.assertEqual(len(records), 3)  # 历史包只由显式Python API核验，不放宽发行CLI。

    def test_unknown_macho_component_is_rejected(self):
        app = self.app()
        shutil.copy2(self.universal, app / 'Contents/Library/HelperTools/未登记的组件')
        result = self.check(app)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('未登记', result.stderr)

    def test_build_selects_both_engines_and_architectures_by_default(self):
        self.check_build_selection(None, ['arm64', 'x86_64'])

    def test_build_selects_explicit_single_architecture(self):
        for arch in ['arm64', 'x86_64']:
            self.check_build_selection(arch, [arch])

    def check_build_selection(self, arch, expected):
        work = Path(tempfile.mkdtemp(prefix='构建选择-', dir=self.work))
        (work / 'script').mkdir()
        (work / 'bin').mkdir()
        shutil.copy2(ROOT / 'script/build_and_run.sh', work / 'script/build_and_run.sh')
        engine = work / 'script/build_engine.sh'
        engine.write_text('#!/bin/sh\nprintf "%s\\n" "$NTFS_BUILD_ARCH" >> engine_calls\n')
        engine.chmod(0o755)
        legacy = work / 'script/build_legacy_backend.sh'
        legacy.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> legacy_calls\n')
        legacy.chmod(0o755)
        generator = work / 'bin/xcodegen'
        generator.write_text('#!/bin/sh\nexit 0\n')
        generator.chmod(0o755)
        builder = work / 'bin/xcodebuild'
        builder.write_text(f'#!{sys.executable}\nimport json,sys\nfrom pathlib import Path\n'
                           "Path('xcode_calls.json').write_text(json.dumps(sys.argv[1:]))\nsys.exit(93)\n")
        builder.chmod(0o755)
        environment = dict(os.environ, PATH=str(work / 'bin') + os.pathsep + os.environ['PATH'])
        environment.pop('NTFS_BUILD_ARCH', None)
        if arch:
            environment['NTFS_BUILD_ARCH'] = arch
        result = subprocess.run(['bash', str(work / 'script/build_and_run.sh'), '--build-only'],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)  # 在构建边界停止，不执行签名。
        self.assertEqual((work / 'engine_calls').read_text().splitlines(), expected)
        self.assertEqual((work / 'legacy_calls').read_text().splitlines(), expected)
        arguments = json.loads((work / 'xcode_calls.json').read_text())
        self.assertIn('ARCHS=' + ' '.join(expected), arguments)
        self.assertIn('ONLY_ACTIVE_ARCH=NO', arguments)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', arguments)

    def test_signing_gate_rejects_missing_slice_before_copy_or_signing(self):
        work = Path(tempfile.mkdtemp(prefix='签名前门禁-', dir=self.work))
        (work / 'script').mkdir()
        for name in ['sign_app.sh', 'check_app_architecture.py']:
            shutil.copy2(ROOT / 'script' / name, work / 'script' / name)
        (work / 'script/check_signing.py').write_text('raise SystemExit(0)\n')
        source = self.app('arm64')
        destination = work / 'build/xcode/Build/Products/Debug/NTFSWorkbench.app'
        destination.parent.mkdir(parents=True)
        shutil.copytree(source, destination)
        environment = dict(os.environ)
        environment.pop('NTFS_BUILD_ARCH', None)
        environment.pop('NTFS_BUILD_CONFIGURATION', None)
        environment.update(NTFS_MINIMUM_SYSTEM='26.0', NTFS_EXTENSION_MINIMUM_SYSTEM='26.0')
        result = subprocess.run(['bash', str(work / 'script/sign_app.sh'), '未使用的描述文件', '未使用的证书'],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('架构', result.stderr)
        self.assertFalse((work / 'build/signed').exists())

    def test_build_and_signing_forward_explicit_minimum_versions(self):
        for script in ['build_and_run.sh', 'sign_app.sh']:
            work = Path(tempfile.mkdtemp(prefix='部署预期传递-', dir=self.work))
            (work / 'script').mkdir()
            (work / 'bin').mkdir()
            for name in [script, 'check_app_architecture.py']:
                shutil.copy2(ROOT / 'script' / name, work / 'script' / name)
            for command in ['xcodegen', 'xcodebuild', '../script/build_engine.sh', '../script/build_legacy_backend.sh']:
                path = work / 'bin' / command
                path.write_text('#!/bin/sh\nexit 0\n')
                path.chmod(0o755)
            wrapper = work / 'bin/python3'
            wrapper.write_text(f'#!{sys.executable}\nimport subprocess,sys\n'
                               "if sys.argv[1].endswith('check_signing.py'): sys.exit(0)\n"
                               "assert '--require-legacy' in sys.argv\n"
                               f"result=subprocess.run([{sys.executable!r}, *sys.argv[1:]])\n"
                               'sys.exit(91 if result.returncode == 0 else result.returncode)\n')
            wrapper.chmod(0o755)
            destination = work / 'build/xcode/Build/Products/Debug/NTFSWorkbench.app'
            destination.parent.mkdir(parents=True)
            shutil.copytree(self.app(minimum='13.0', extension_minimum='15.4'), destination)
            arguments = ['--build-only'] if script == 'build_and_run.sh' else ['未使用的描述文件', '未使用的证书']
            environment = dict(os.environ, PATH=str(work / 'bin') + os.pathsep + os.environ['PATH'],
                               NTFS_BUILD_ARCH='universal', NTFS_BUILD_CONFIGURATION='Debug',
                               NTFS_MINIMUM_SYSTEM='13.0', NTFS_EXTENSION_MINIMUM_SYSTEM='15.4')
            result = subprocess.run(['bash', str(work / 'script' / script), *arguments],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 91, result.stderr)  # 门禁通过后即停，不执行签名。
            self.assertFalse((work / 'build/signed').exists())

    def test_unknown_build_architecture_is_rejected_before_build(self):
        result = subprocess.run(['bash', 'script/build_and_run.sh', '--build-only'], cwd=ROOT,
                                env=dict(os.environ, NTFS_BUILD_ARCH='unsupported-test-architecture'),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('NTFS_BUILD_ARCH', result.stderr)


if __name__ == '__main__':
    unittest.main()
