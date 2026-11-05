#!/usr/bin/env python3
"""确定性模拟命令返回；不创建镜像，不执行系统命令或设备操作。"""
from pathlib import Path
import plistlib
from 测试镜像清理 import release_owned_image

IMAGE=Path('/private/tmp/writeflow-owned-only/本次.img')
CAPACITY=64*1024*1024

class Fixture:
    def __init__(self, *, virtual=True, size=CAPACITY, mount='', missing=False, change=False):
        self.virtual=virtual;self.size=size;self.mount=mount;self.missing=missing;self.change=change
        self.calls=[];self.mapping_reads=0;self.detached=False
    def run(self,args):
        self.calls.append(args)
        if args==['hdiutil','info','-plist']:
            self.mapping_reads+=1
            own=[] if self.missing or self.detached else [{'image-path':str(IMAGE),'system-entities':[{'dev-entry':'/dev/disk98' if self.change and self.mapping_reads>1 else '/dev/disk99'}]}]
            return plistlib.dumps({'images':own+[{'image-path':'/private/tmp/other.img','system-entities':[{'dev-entry':'/dev/disk1'}]}]})
        if args==['diskutil','info','-plist','/dev/disk99']:
            return plistlib.dumps({'VirtualOrPhysical':'Virtual' if self.virtual else 'Physical','IOKitSize':self.size,'MountPoint':self.mount})
        if args==['diskutil','unmount','/dev/disk99']:
            self.mount='';return b''
        if args==['hdiutil','detach','/dev/disk99']:
            self.detached=True;return b''
        raise AssertionError('操作了非目标设备或出现意外命令')

def expect_refusal(fixture):
    try:release_owned_image(IMAGE,CAPACITY,fixture.run)
    except AssertionError:pass
    else:raise AssertionError('未知状态未拒绝')
    assert not any(x[0]=='hdiutil' and x[1]=='detach' for x in fixture.calls)
    assert not any(x[0]=='diskutil' and x[1]=='unmount' for x in fixture.calls)

# 模拟attach已经失败、没有可用device变量，但路径映射实际仍存在。
f=Fixture();r=release_owned_image(IMAGE,CAPACITY,f.run)
assert r['清理前目标映射数']==1 and r['正常分离执行'] and r['最终目标映射数']==0
for f in [Fixture(virtual=False),Fixture(size=CAPACITY+512),Fixture(mount='/Volumes/未知'),Fixture(change=True)]:expect_refusal(f)
f=Fixture(missing=True);r=release_owned_image(IMAGE,CAPACITY,f.run);assert not r['正常分离执行']
f=Fixture(mount='/Volumes/本次已知');r=release_owned_image(IMAGE,CAPACITY,f.run,'/Volumes/本次已知');assert r['正常分离执行']
assert ['diskutil','unmount','/dev/disk99'] in f.calls
print('通过：七项精确路径、失败残留、物理属性、容量、未知挂载、换代与正常卸载清理检查；没有真实设备操作。')
