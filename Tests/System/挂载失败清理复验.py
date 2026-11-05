#!/usr/bin/env python3
"""无参数：自行创建64MiB NTFS，保留真实挂载失败，并验收失败后的精确路径清理。"""
from pathlib import Path
import hashlib,json,subprocess,sys,tempfile
from 测试镜像清理 import release_owned_image
ROOT=Path(__file__).resolve().parents[2]
assert len(sys.argv)==1
OUT=Path(tempfile.mkdtemp(prefix='挂载失败清理-',dir=ROOT/'build/0.2.0'))
image=OUT/'本次.img'
with image.open('wb') as f:f.truncate(64*1024*1024)
def command(args,required=True):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=40)
    (OUT/f'命令-{len(list(OUT.glob("命令-*"))):03}.json').write_text(json.dumps({'参数':list(map(str,args)),'退出码':p.returncode,'输出':p.stdout.decode(errors='replace'),'错误':p.stderr.decode(errors='replace')},ensure_ascii=False,indent=2))
    if required and p.returncode:raise RuntimeError('命令失败：'+str(args[0]))
    return p
run=lambda args:command(args).stdout
run([ROOT/'build/engine/arm64/ntfsprogs/mkntfs','-F','-Q','-L','WF_FAILED_CLEANUP',image])
before=hashlib.sha256(image.read_bytes()).hexdigest()
result={'范围':'只操作本次新建64MiB镜像；挂载结果与清理验收分别记录'}
try:
    p=command(['hdiutil','attach','-readonly','-mount','optional','-nobrowse','-plist',image],False)
    result['挂载原始退出码']=p.returncode
    result['挂载结果']='失败' if p.returncode else '意外成功，未复现失败路径'
finally:
    try:result.update(release_owned_image(image,64*1024*1024,run))
    except Exception as error:result['清理错误']=str(error)
    result['镜像摘要不变']=hashlib.sha256(image.read_bytes()).hexdigest()==before
    passed=result.get('挂载原始退出码',0)!=0 and result.get('清理前目标映射数')==1 and result.get('正常分离执行') and result.get('镜像已正常释放') and result['镜像摘要不变']
    result['失败后清理验收']='通过' if passed else '失败或未覆盖预期残留'
    (OUT/'结果.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False));print(OUT)
sys.exit(0 if passed else 1)
