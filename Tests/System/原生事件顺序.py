#!/usr/bin/env python3
"""无参数入口：只读接入自身新建镜像，记录真实生产回调顺序，不设置任何拦截规则。"""
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys, tempfile, time
from 测试镜像清理 import release_owned_image
ROOT = Path(__file__).resolve().parents[2]
assert len(sys.argv) == 1
OUT = Path(tempfile.mkdtemp(prefix='原生事件顺序-', dir=ROOT/'build/0.2.0'))
image = OUT/'本次.dmg'
def run(args):
    p = subprocess.run(list(map(str,args)), capture_output=True, timeout=40)
    (OUT/f'命令-{len(list(OUT.glob("命令-*"))):03}.json').write_text(json.dumps({'参数':list(map(str,args)), '退出码':p.returncode,'输出':p.stdout.decode(errors='replace'),'错误':p.stderr.decode(errors='replace')}, ensure_ascii=False,indent=2))
    if p.returncode: raise RuntimeError('命令失败：'+str(args[0]))
    return p.stdout
run(['hdiutil','create','-size','64m','-layout','NONE','-fs','HFS+','-volname','WF_SEQUENCE',image])
before = hashlib.sha256(image.read_bytes()).hexdigest()
probe = subprocess.Popen([ROOT/'build/0.2.0/原生事件顺序'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,text=True)
device = None
expected_mount = None
result = {'范围':'新建HFS+只读镜像真实原生回调；无策略、无GUID注入；只证明共用DA时序，不证明NTFS实体自动接管'}
def mapping():
    return [x for x in plistlib.loads(run(['hdiutil','info','-plist']))['images'] if Path(x['image-path']).resolve()==image.resolve()]
def verify():
    items=mapping()
    assert len(items)==1 and [x['dev-entry'] for x in items[0]['system-entities']]==[device]
    info=plistlib.loads(run(['diskutil','info','-plist',device]))
    assert info['VirtualOrPhysical']=='Virtual' and info['IOKitSize']==64*1024*1024
try:
    assert probe.stdout.readline().strip() == '监控就绪'
    data=plistlib.loads(run(['hdiutil','attach','-readonly','-mount','optional','-nobrowse','-plist',image]))
    assert len(data['system-entities'])==1
    device=data['system-entities'][0]['dev-entry']
    expected_mount=data['system-entities'][0].get('mount-point')
    verify()
    identity=run([ROOT/'build/system-tests/只读介质身份',device.removeprefix('/dev/')]).decode().strip()
    time.sleep(1)
    output, errors=probe.communicate('结束\n',timeout=15)
    assert probe.returncode==0, errors
    events=[x for x in json.loads(output) if x['BSD']==device.removeprefix('/dev/') and x['介质ID']==identity]
    result['事件']=events
    approvals=[x for x in events if x['阶段']=='approval']
    assert approvals, '本次接入没有经过挂载批准，不能证明批准缓存路径'
    result['批准回调均有同代身份缓存']=all(x['同代缓存命中'] for x in approvals)
    result['挂载前预采集先于其他通知']=bool(events) and events[0]['阶段']=='peek'
    result['结果']='通过' if result['批准回调均有同代身份缓存'] and result['挂载前预采集先于其他通知'] else '失败'
except Exception as error:
    result.update(结果='失败',错误=str(error))
finally:
    if probe.poll() is None:
        try: probe.communicate('结束\n',timeout=10)
        except subprocess.TimeoutExpired: probe.terminate()
    try:
        result.update(release_owned_image(image,64*1024*1024,run,expected_mount))
    except Exception as error: result['清理错误']=str(error)
    result['镜像SHA一致']=hashlib.sha256(image.read_bytes()).hexdigest()==before
    (OUT/'结果.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False));print(OUT)
sys.exit(0 if result.get('结果')=='通过' and result.get('镜像已正常释放') and result['镜像SHA一致'] else 1)
