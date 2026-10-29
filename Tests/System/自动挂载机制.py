#!/usr/bin/env python3
"""只在新建64MiB镜像上验证DA一次拒绝和随后显式只读挂载；不接受参数。"""
from pathlib import Path
import subprocess, tempfile, plistlib, json, hashlib, sys, os
ROOT = Path(__file__).resolve().parents[2]
assert len(sys.argv) == 1
OUT = Path(tempfile.mkdtemp(prefix='DA机制-', dir=ROOT/'build/0.2.0'))
image = OUT/'本次.img'
mountpoint = Path(tempfile.mkdtemp(prefix='writeflow-da-',dir='/private/tmp'))/'mount'
mountpoint.mkdir(mode=0o700)
image.write_bytes(b'')
with image.open('r+b') as f: f.truncate(64*1024*1024)
def run(args):
    p=subprocess.run(list(map(str,args)),capture_output=True)
    (OUT/f'命令-{len(list(OUT.glob("命令-*"))):03}.json').write_text(json.dumps({'参数':list(map(str,args)),'退出码':p.returncode,'输出':p.stdout.decode(errors='replace'),'错误':p.stderr.decode(errors='replace')},ensure_ascii=False,indent=2))
    if p.returncode: raise RuntimeError(f'命令失败：{args[0]}，退出码{p.returncode}')
    return p.stdout
run([ROOT/'build/engine/arm64/ntfsprogs/mkntfs','-F','-Q','-L','WF_DA_PROBE',image])
before=hashlib.sha256(image.read_bytes()).hexdigest()
device=None
result={'范围':'仅新建镜像与只读挂载，非20轮物理插盘，非自动RW验收'}
def mapping():
    return [x for x in plistlib.loads(run(['hdiutil','info','-plist']))['images'] if Path(x['image-path']).resolve()==image.resolve()]
try:
    data=plistlib.loads(run(['hdiutil','attach','-nomount','-nobrowse','-readwrite','-plist',image]))
    assert len(data['system-entities'])==1
    device=data['system-entities'][0]['dev-entry']
    def verify():
        items=mapping(); assert len(items)==1 and [x['dev-entry'] for x in items[0]['system-entities']]==[device]
        info=plistlib.loads(run(['diskutil','info','-plist',device]))
        assert info['VirtualOrPhysical']=='Virtual' and info['IOKitSize']==64*1024*1024
    verify()
    identity=run([ROOT/'build/system-tests/只读介质身份',device.removeprefix('/dev/')]).decode().strip()
    run([ROOT/'build/0.2.0/DA机制验证',device.removeprefix('/dev/'),identity,mountpoint])
    lines=run(['mount']).decode().splitlines()
    assert any(x.startswith(device+' on '+str(mountpoint)+' (blntfs,') and 'read-only' in x for x in lines)
    result['结果']='通过'
except Exception as error:
    result.update(结果='失败',错误=str(error))
finally:
    if device:
        try:
            verify()
            info=plistlib.loads(run(['diskutil','info','-plist',device]))
            if info.get('MountPoint'):
                assert Path(info['MountPoint']).resolve()==mountpoint.resolve()
                run(['diskutil','unmount',device])
            verify();run(['hdiutil','detach',device])
            assert not mapping()
            result['镜像已正常释放']=True
        except Exception as error: result['清理错误']=str(error)
    result['只读前后镜像SHA一致']=hashlib.sha256(image.read_bytes()).hexdigest()==before
    (OUT/'结果.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False));print(OUT)
sys.exit(0 if result.get('结果')=='通过' and result.get('镜像已正常释放') and result['只读前后镜像SHA一致'] else 1)
