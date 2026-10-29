"""仅由无参数自建镜像的Swift验收入口调用；不是生产运行器的旁路开关。"""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).parent))
import benchmark as b
from workloads import fio_workload

def run(context):
    # 上层Swift仅为本轮自建镜像生成上下文，再次独立验证映射，拒绝物理介质。
    target=Path(context['target']);image=Path(context['image'])
    if not image.name=='本次.img' or not image.parent.name.startswith('writeflow-permission-probe-'):
        raise RuntimeError('仅本轮自动创建镜像可运行此测试。')
    import plistlib
    info=plistlib.loads(subprocess.run(['/usr/bin/hdiutil','info','-plist'],capture_output=True,check=True,timeout=10).stdout)
    owned=[x for x in info['images'] if Path(x['image-path']).resolve()==image.resolve()]
    if len(owned)!=1 or [x['dev-entry'] for x in owned[0]['system-entities']]!=[context['device']]:
        raise RuntimeError('本次镜像映射不一致。')
    before=b.probe(context['probe'],target)
    if before['source']!=context['device'] or before['capacity']!=128*1024**2 or before['virtual'] is not True or before['provider']!='blntfs' or before['read_only']:
        raise RuntimeError('不是本次128MiB虚拟blntfs读写镜像。')
    try:b.validate_target(before,'blntfs',before['media_id'],before['capacity'])
    except b.Refusal:pass
    else:raise RuntimeError('生产门禁错误接受虚拟介质。')
    manifest=json.loads(Path(context['manifest']).read_text());fio=Path(context['fio'])
    if manifest['commit']!=b.PIN or manifest['binary_sha256']!=b.digest(fio):raise RuntimeError('本机构建fio摘要不符。')
    fd=os.open(target,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);anchor=None
    try:
        if os.listdir(fd):raise RuntimeError('本次新建测试目录必须为空。')
        anchor=b.open_isolation(fd,target,before)
        if anchor is None:raise RuntimeError('本次测试要求真实经过外层隔离路径。')
        write=fio_workload(fio,fd,'sequential-write',4*1024**2,1,False,120,True)
        read=fio_workload(fio,fd,'sequential-read',4*1024**2,1,False,120,False)
        if write['file_hashes']!=read['file_hashes']:raise RuntimeError('写后全量复读摘要不一致。')
        after=b.probe(context['probe'],target)
        if before!=after:raise RuntimeError('镜像身份或外层隔离证明变化。')
        fresh=b.open_isolation(fd,target,after)
        try:
            a=os.fstat(anchor);c=os.fstat(fresh)
            if (a.st_dev,a.st_ino)!=(c.st_dev,c.st_ino):raise RuntimeError('外层隔离FD变化。')
        finally:os.close(fresh)
        return dict(status='passed',fixture_boundary=True,actual_target=after,write=write,read=read,
                    limitation='真实blntfs镜像4MiB内部执行器与隔离验证，不是物理性能、完整ABBA或Paragon对比')
    finally:
        if anchor is not None:os.close(anchor)
        os.close(fd)
