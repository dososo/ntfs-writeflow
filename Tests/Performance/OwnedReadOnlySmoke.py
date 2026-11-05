"""无参数Swift镜像入口使用的准备/只读复核片段；无生产virtual旁路。"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid
import benchmark as b
from OwnedImageSmoke import run

def stage(context,phase):
    image=Path(context['image']);host=Path(context['source_report']).parent
    if host.resolve()!=image.parent.resolve() or image.name!='本次.img' or not image.parent.name.startswith('writeflow-permission-probe-'):
        raise RuntimeError('仅本轮自建镜像及其宿主报告目录可用。')
    if phase=='prepare':
        result=run(context) # 已有内部执行器：本轮空目录、真实映射及4MiB写/完整读回。
        directory=Path(context['target']);token=str(uuid.uuid4())
        if not directory.name.startswith('WriteFlow-Benchmark-'):raise RuntimeError('不是本工具session目录。')
        fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            marker=os.open('.writeflow-owner.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
            try:os.write(marker,json.dumps(dict(schema=1,token=token)).encode());os.fsync(marker)
            finally:os.close(marker)
        finally:os.close(fd)
        state=result['actual_target']
        source=dict(schema=2,status='passed',fixture_boundary=True,run_id=str(uuid.uuid4()),provider='blntfs',
            media_id=state['media_id'],capacity=state['capacity'],session_name=directory.name,owner_token=token,
            workload='sequential-write',size_bytes=4*b.MIB,concurrency=1,small_file_count=0,file_hashes=result['write']['file_hashes'])
        b.validate_source_report(source)
        with Path(context['source_report']).open('x') as output:json.dump(source,output,ensure_ascii=False,indent=2)
        return dict(status='passed',source=source,preparation=result)
    if phase!='verify':raise RuntimeError('阶段无效。')
    mapping=plistlib.loads(subprocess.run(['/usr/bin/hdiutil','info','-plist'],capture_output=True,check=True,timeout=10).stdout)
    images=[x for x in mapping['images'] if Path(x['image-path']).resolve()==image.resolve()]
    if len(images)!=1 or [x['dev-entry'] for x in images[0]['system-entities']]!=[context['device']]:raise RuntimeError('只读复核前镜像映射不一致。')
    before=b.probe(context['probe'],context['target'])
    if before['source']!=context['device'] or before['capacity']!=128*1024**2 or before['virtual'] is not True or before['provider']!='blntfs' or before['read_only'] is not True:
        raise RuntimeError('本次镜像没有经生产DiskService正常只读重挂。')
    try:b.validate_target(before,'blntfs',before['media_id'],before['capacity'],read_only=True)
    except b.Refusal:pass
    else:raise RuntimeError('生产物理盘门禁错误接受镜像。')
    source=b.read_owned_json(context['source_report'])
    result=b.verify_owned_workset(Path(context['target']),source,before,context['probe'],'blntfs',before['media_id'],before['capacity'])
    result['fixture_boundary']=True
    with (host/'只读复核.json').open('x') as output:json.dump(result,output,ensure_ascii=False,indent=2)
    return result
