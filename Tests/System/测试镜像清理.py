"""仅清理调用方本次新建镜像的精确映射；未知设备或挂载状态保留并报错。"""
from pathlib import Path
import plistlib
import re


def release_owned_image(image, capacity, run, expected_mount=None):
    image = Path(image).resolve()

    def mappings():
        values = plistlib.loads(run(['hdiutil', 'info', '-plist']))['images']
        assert isinstance(values, list), '镜像映射列表不可核实'
        return [entry for entry in values if Path(entry['image-path']).resolve() == image]

    initial = mappings()
    result = {'清理前目标映射数': len(initial), '正常分离执行': False}
    if initial:
        assert len(initial) == 1 and len(initial[0]['system-entities']) == 1, '目标映射不是唯一单介质，保留'
        device = initial[0]['system-entities'][0]['dev-entry']
        assert re.fullmatch(r'/dev/disk[0-9]+', device), '不是预期的单一完整镜像设备，保留'

        def verify():
            current = mappings()
            assert len(current) == 1 and [x['dev-entry'] for x in current[0]['system-entities']] == [device], '目标映射已变化，保留'
            info = plistlib.loads(run(['diskutil', 'info', '-plist', device]))
            assert info.get('VirtualOrPhysical') == 'Virtual' and info.get('IOKitSize') == capacity, '虚拟属性或容量不符，保留'
            mount = info.get('MountPoint')
            assert not mount or (expected_mount is not None and Path(mount).resolve() == Path(expected_mount).resolve()), '发现未知挂载点，保留'
            return info

        info = verify()
        if info.get('MountPoint'):
            run(['diskutil', 'unmount', device])
        assert not verify().get('MountPoint'), '正常卸载未确认，保留'
        run(['hdiutil', 'detach', device])
        result['正常分离执行'] = True
    result['最终目标映射数'] = len(mappings())
    assert result['最终目标映射数'] == 0, '正常分离后目标映射仍存在'
    result['镜像已正常释放'] = True
    return result
