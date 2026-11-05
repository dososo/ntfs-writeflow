#!/usr/bin/env python3
"""核对发行包内 Mach-O 架构、每个切片及应用声明的最低系统。"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError('最低系统版本格式无效。')
    return tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.')))


def inspect_app(app, architecture, minimum, extension_minimum, require_legacy=True):
    expected = {'arm64', 'x86_64'} if architecture == 'universal' else {architecture}
    executables = []
    for contents, target_minimum in [(app / 'Contents', minimum),
                                      (app / 'Contents/Extensions/NTFSFileSystem.appex/Contents', extension_minimum)]:
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        if version(info.get('LSMinimumSystemVersion')) != version(target_minimum):
            raise ValueError(f'最低系统声明不符：{contents / "Info.plist"}')
        name = info.get('CFBundleExecutable')
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise ValueError(f'可执行文件声明无效：{contents}')
        executables.append((contents / 'MacOS' / name, target_minimum))
        executables.extend((path, target_minimum) for path in sorted((contents / 'MacOS').glob('*.dylib')))
    executables.append((app / 'Contents/Library/HelperTools/NTFSWriteFlowMountHelper', minimum))
    legacy = app / 'Contents/Library/HelperTools/NTFSWriteFlowLegacy'
    if require_legacy and not legacy.is_file():
        raise ValueError(f'缺少发行必需的兼容前端：{legacy}')
    if legacy.exists() or legacy.is_symlink():
        executables.append((legacy, minimum))
    known = {path for path, _ in executables}
    macho_magic = {bytes.fromhex(value) for value in
                   ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
    for path in app.rglob('*'):
        if path.is_file() and path not in known:
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic in macho_magic or path.stat().st_mode & 0o111:
                raise ValueError(f'未登记的执行组件：{path}')
    records = []
    for path, target_minimum in executables:
        if not path.is_file():
            raise ValueError(f'缺少可执行组件：{path}')
        slices = set(subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split())
        if slices != expected:
            raise ValueError(f'架构不符：{path}；预期 {sorted(expected)}，实际 {sorted(slices)}')
        for arch in sorted(slices):
            output = subprocess.check_output(['xcrun', 'vtool', '-arch', arch, '-show-build', str(path)], text=True)
            platforms = re.findall(r'^\s*platform\s+(\S+)', output, re.MULTILINE)
            versions = re.findall(r'^\s*minos\s+(\S+)', output, re.MULTILINE)
            if platforms != ['MACOS'] or len(versions) != 1 or version(versions[0]) != version(target_minimum):
                raise ValueError(f'Mach-O 最低系统或平台不符：{path}（{arch}）')
        records.append({'文件': str(path), '架构': sorted(slices), '最低系统': target_minimum})
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'], default='universal')
    parser.add_argument('--require-legacy', action='store_true', default=True, help='发行CLI始终要求兼容前端；历史包仅可用显式Python API')
    parser.add_argument('--minimum-system', default='13.0')
    parser.add_argument('--extension-minimum-system', default='15.4')
    args = parser.parse_args()
    try:
        records = inspect_app(args.app, args.arch, args.minimum_system, args.extension_minimum_system, args.require_legacy)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f'发行架构门禁拒绝：{error}', file=sys.stderr)
        return 1
    print(json.dumps({'通过': True, '组件': records}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
