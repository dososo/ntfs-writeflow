#!/usr/bin/env python3
"""受保护的逐步性能实验、累计预算账本和结果汇总；不切换驱动或清理文件。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import stat
import subprocess
import time
import uuid
import re
from contextlib import nullcontext
from ledger import Ledger
from workloads import fio_workload, small_files, hashes

GIB=1024**3
MIB=1024**2
PIN='f8127399732876749f4855fb35ac3b8693fc7463'
SEED=20261029
HELPER_NAMESPACE='/private/var/db/com.blteam.ntfsworkbench.mounts'
class Refusal(RuntimeError): pass
class Waiting(Refusal): pass

def make_plan():
    steps=[]
    def add(provider,cache,workload,budget,size=0,sample=0,concurrency=1):
        steps.append(dict(id=f'step-{len(steps)+1:03d}',provider=provider,cache=cache,workload=workload,
            write_budget_bytes=budget,size_bytes=size,sample=sample,concurrency=concurrency,seed=SEED,
            executable=True))
        if workload in ['sequential-read','random-write','random-read']:
            dependency={'sequential-read':'sequential-write','random-write':'random-initialize','random-read':'random-write'}[workload]
            steps[-1]['depends_on']=next(x['id'] for x in reversed(steps[:-1]) if x['workload']==dependency and x['provider']==provider and x['cache']==cache and x['sample']==sample and x['concurrency']==concurrency)
    allowance=8*GIB
    for cache in ['buffered','nocache-requested']:
        for provider in ['blntfs','ufsd_NTFS']:
            add(provider,cache,'preflight-smoke',2*GIB,2*GIB)
            add(provider,cache,'prewarm',32*GIB,32*GIB)
        counts={'blntfs':0,'ufsd_NTFS':0}
        for provider in ['blntfs','ufsd_NTFS','ufsd_NTFS','blntfs']*3:
            counts[provider]+=1;sample=counts[provider]
            add(provider,cache,'sequential-write',32*GIB,32*GIB,sample)
            add(provider,cache,'sequential-read',0,32*GIB,sample)
            for concurrency in [1,4]:
                add(provider,cache,'random-initialize',GIB,GIB,sample,concurrency)
                add(provider,cache,'random-write',GIB,GIB,sample,concurrency)
                add(provider,cache,'random-read',0,GIB,sample,concurrency)
            # 小文件/同步每样本共享有界额度，实际写量另记。
            slots_left=24-sum(s['workload']=='small-files-and-sync' for s in steps)
            budget=allowance//slots_left;allowance-=budget
            add(provider,cache,'small-files-and-sync',budget,10000*4096,sample=sample)
    total=sum(s['write_budget_bytes'] for s in steps)
    assert total==1008*GIB
    return dict(schema=1,fio_commit=PIN,seed=SEED,maximum_write_bytes=total,limit_bytes=1024*GIB,cache_limit_bytes=512*GIB,
        explanation='direct=1在macOS请求F_NOCACHE，不代表冷缓存。逻辑写入不含元数据/闪存写放大。',
        steps=steps,unimplemented=['驱动切换必须人工完成，不提供自动切换','连续系统级CPU与内存采样','真实跨驱动与Windows复读验收','掉电/重挂数据安全验收'])

def validate_path(path):
    path=Path(path)
    if not path.is_absolute() or str(path).startswith('/dev/') or not path.is_dir():raise Refusal('目标必须为已存在的外部卷专用目录，拒绝原始设备。')
    if path.resolve()!=path:raise Refusal('目标路径包含符号链接或非规范路径。')
    for component in [path,*path.parents]:
        if component.is_symlink():raise Refusal('目标路径含符号链接。')

def validate_volume_identity(state,provider,media_id,capacity,read_only=False):
    if provider not in ['blntfs','ufsd_NTFS']:raise Refusal('仅接受明确的WriteFlow或Paragon实际挂载类型。')
    if state.get('provider')!=provider:raise Waiting('等待外部明确切换驱动：实际提供方不符；本工具不会切换或卸载。')
    if state.get('media_id')!=media_id or state.get('capacity')!=capacity:raise Refusal('介质身份或容量未核实。')
    if state.get('read_only') is not read_only:
        raise Refusal('只读复核必须人工正常卸载并只读重挂；不会自动切换。' if read_only else '介质可写状态未核实。')

def validate_target(state,provider,media_id,capacity,read_only=False):
    if state.get('internal') is not False or state.get('virtual') is not False:raise Refusal('正式执行只接受外部物理卷。')
    validate_volume_identity(state,provider,media_id,capacity,read_only)

def probe(binary,path):
    # 仅执行仓库构建的只读查询工具；超时由父进程终止该次自有查询。
    result=subprocess.run([str(binary),str(path)],capture_output=True,timeout=10,check=True)
    if len(result.stdout)>1_048_576:raise Refusal('查询输出超限。')
    return json.loads(result.stdout)

def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for data in iter(lambda:f.read(MIB),b''):h.update(data)
    return h.hexdigest()

def open_isolation(directory,session,state):
    st=os.fstat(directory)
    if st.st_uid==os.getuid() and state.get('mount_owner_uid')==os.getuid() and not stat.S_IMODE(st.st_mode)&0o077 and state.get('directory_empty_acl') is True:
        if (state.get('directory_device'),state.get('directory_inode'))!=(st.st_dev,st.st_ino):raise Refusal('私有目录探针与持有FD不同。')
        return None
    proof=state.get('isolation')
    if not isinstance(proof,dict) or proof.get('schema')!=1:raise Refusal('目标目录无私有权限，且未证明外层隔离。')
    anchor=Path(proof.get('path',''))
    mount=Path(state.get('mount_point',''))
    if not anchor.is_absolute() or not mount.is_absolute() or anchor==mount or anchor not in mount.parents or mount not in [session,*session.parents]:
        raise Refusal('外层隔离祖先与真实挂载点不匹配。')
    kind=proof.get('isolation_kind')
    owner=os.getuid()
    if kind=='helper-root-acl':
        owner=0
        if anchor!=Path(HELPER_NAMESPACE)/str(os.getuid()) or proof.get('caller_uid')!=os.getuid() or state.get('mount_owner_uid')!=0:
            raise Refusal('助手隔离用户层/连接用户/root挂载身份不符。')
        parts=mount.relative_to(anchor).parts
        if len(parts)!=2 or parts[1]!='volume':raise Refusal('助手隔离挂载路径结构不符。')
        try:token=str(uuid.UUID(parts[0])).upper()
        except ValueError:raise Refusal('助手隔离UUID无效。')
        if token!=parts[0]:raise Refusal('助手隔离UUID非规范格式。')
    elif kind=='direct-uid':
        if proof.get('caller_uid')!=os.getuid() or state.get('mount_owner_uid')!=os.getuid():raise Refusal('直接挂载隔离未绑定当前用户。')
    else:raise Refusal('未知外层隔离类型。')
    if proof.get('uid')!=owner or proof.get('mode')!=0o700 or proof.get('same_mount_count')!=1 or proof.get('identity')==state.get('mount_identity'):
        raise Refusal('外层隔离所有权/模式/独立挂载证明不符。')
    if any(proof.get(k)!=state.get(k) for k in ['mount_identity','mount_point','source']):raise Refusal('外层隔离未绑定本次挂载。')
    if (state.get('directory_device'),state.get('directory_inode'))!=(st.st_dev,st.st_ino):raise Refusal('查询工具核验的目录与持有FD不同。')
    validate_path(anchor)
    held=os.open(anchor,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    observed=os.fstat(held)
    if (observed.st_dev,observed.st_ino)!=(proof.get('device'),proof.get('inode')) or observed.st_uid!=owner or stat.S_IMODE(observed.st_mode)!=0o700:
        os.close(held);raise Refusal('外层隔离祖先已被替换或权限变化。')
    return held

def read_owned_json(path,directory=None,limit=8*MIB):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_nlink!=1 or not 0<st.st_size<=limit:
            raise Refusal('报告或所有权标记不是当前用户的单链接有界普通文件。')
        raw=bytearray()
        while len(raw)<=limit:
            block=os.read(fd,min(MIB,limit+1-len(raw)))
            if not block:break
            raw.extend(block)
        if len(raw)>limit:raise Refusal('报告或所有权标记超限。')
        return json.loads(raw.decode('utf-8'))
    finally:os.close(fd)

def validate_source_report(source):
    if source.get('status')!='passed' or source.get('schema')!=2 or source.get('provider') not in ['blntfs','ufsd_NTFS']:
        raise Refusal('仅接受本工具原始成功工作集报告。')
    session=source.get('session_name','');prefix='WriteFlow-Benchmark-'
    if not session.startswith(prefix) or str(uuid.UUID(session[len(prefix):]))!=session[len(prefix):]:raise Refusal('源报告session目录名无效。')
    token=source.get('owner_token','')
    if str(uuid.UUID(token))!=token:raise Refusal('源报告所有权token无效。')
    files=source.get('file_hashes');size=source.get('size_bytes',0)
    if not isinstance(files,dict) or not 0<len(files)<=10000 or not 0<size<=32*GIB:raise Refusal('源报告工作集大小或清单无效。')
    if source.get('workload')=='small-files-and-sync':
        count=source.get('small_file_count',0)
        if not 1<=count<=10000:raise Refusal('源报告小文件数量无效。')
        expected={f'checked-{n:05d}.dat' for n in range(count)}
    else:
        if source.get('workload') not in ['preflight-smoke','prewarm','sequential-write','sequential-read','random-initialize','random-write','random-read']:
            raise Refusal('源报告负载类型不支持。')
        count=source.get('concurrency')
        if count not in [1,4]:raise Refusal('源报告并发数无效。')
        expected={f'workload.{n}.dat' for n in range(count)}
    if set(files)!=expected:raise Refusal('源报告文件名不在工具工作集白名单内。')
    for info in files.values():
        if not isinstance(info,dict) or not isinstance(info.get('size'),int) or not 0<info['size']<=32*GIB or not re.fullmatch('[a-f0-9]{64}',info.get('sha256','')):
            raise Refusal('源报告文件长度或SHA256无效。')
    if sum(info['size'] for info in files.values())!=size:raise Refusal('源报告总长度与文件清单不一致。')

def verify_owned_workset(target,source,before,probe_binary,provider,media_id,capacity):
    # 内部只读执行器；生产入口另强制物理介质，镜像测试仅在独立自建映射核验后调用。
    validate_source_report(source);validate_path(target)
    validate_volume_identity(before,provider,media_id,capacity,read_only=True)
    if source.get('capacity')!=capacity:raise Refusal('源工作集容量与本次明确期望容量不一致。')
    session=Path(target)/source['session_name'];validate_path(session)
    record=dict(schema=2,kind='content-verification',run_id=str(uuid.uuid4()),status='failed',files=[],
        source_run_id=source.get('run_id'),source_provider=source['provider'],provider=provider,
        verification_scope='same-provider' if source['provider']==provider else 'cross-provider',
        media_id=media_id,capacity=capacity,read_only_mount=True,verified_bytes=0,
        limitation='仅读取本工具工作集；同驱动复核不计跨驱动或性能样本；不代表掉电安全。')
    parent=os.open(target,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);directory=None;anchor=None
    try:
        directory=os.open(source['session_name'],os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
        held=os.fstat(directory)
        checked=probe(probe_binary,session);validate_volume_identity(checked,provider,media_id,capacity,read_only=True)
        context=['provider','media_id','capacity','internal','virtual','source','mount_identity','mount_point','mount_owner_uid','read_only']
        if any(checked.get(k)!=before.get(k) for k in context):raise Refusal('工作集与目标初始挂载实例不同。')
        if not isinstance(checked.get('mount_identity'),str) or not checked['mount_identity'] or not re.fullmatch(r'/dev/disk[0-9]+(s[0-9]+)*',checked.get('source','')):
            raise Refusal('工作集缺少实际挂载来源/实例。')
        if (checked.get('directory_device'),checked.get('directory_inode'))!=(held.st_dev,held.st_ino):raise Refusal('工作集查询与持有FD不一致。')
        anchor=open_isolation(directory,session,checked)
        marker=read_owned_json('.writeflow-owner.json',directory,4096)
        if marker!={'schema':1,'token':source['owner_token']}:raise Refusal('工作集所有权标记不一致。')
        for name,expected in source['file_hashes'].items():
            item=dict(name=name,status='failed',expected=expected)
            try:
                first=os.stat(name,dir_fd=directory,follow_symlinks=False)
                if first.st_size!=expected['size']:raise Refusal('文件长度不一致。')
                actual=hashes(directory,[name])[name];item['actual']=actual
                last=os.stat(name,dir_fd=directory,follow_symlinks=False)
                if not stat.S_ISREG(last.st_mode) or last.st_uid!=os.getuid() or last.st_nlink!=1:raise Refusal('复读后文件所有权、类型或链接数变化。')
                if (first.st_dev,first.st_ino,first.st_size,first.st_mtime_ns)!=(last.st_dev,last.st_ino,last.st_size,last.st_mtime_ns) or actual['inode']!=first.st_ino:
                    raise Refusal('读取过程中测试文件发生变化。')
                if actual['sha256']!=expected['sha256'] or actual['size']!=expected['size']:raise Refusal('文件SHA256或长度不一致。')
                item['status']='passed';record['verified_bytes']+=actual['size']
            except Exception as error:item['reason']=str(error)
            record['files'].append(item)
        after=probe(probe_binary,session);validate_volume_identity(after,provider,media_id,capacity,read_only=True)
        if any(after.get(k)!=checked.get(k) for k in context) or after.get('isolation')!=checked.get('isolation'):
            raise Refusal('复核后挂载或隔离实例发生变化。')
        fresh=open_isolation(directory,session,after)
        try:
            if (fresh is None)!=(anchor is None):raise Refusal('复核后隔离类型变化。')
            if fresh is not None:
                a=os.fstat(anchor);b=os.fstat(fresh)
                if (a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino):raise Refusal('复核后隔离祖先FD变化。')
        finally:
            if fresh is not None:os.close(fresh)
        if read_owned_json('.writeflow-owner.json',directory,4096)!=marker:raise Refusal('复核过程中所有权标记变化。')
        actual_path=os.stat(session,follow_symlinks=False)
        if (actual_path.st_dev,actual_path.st_ino)!=(held.st_dev,held.st_ino):raise Refusal('复核后工作集目录被替换。')
        record.update(status='passed' if all(x['status']=='passed' for x in record['files']) else 'failed',
            mount_identity=after['mount_identity'],isolation=after.get('isolation'))
    except Waiting as error:record.update(status='waiting',reason=str(error))
    except Exception as error:record.update(status='failed',reason=str(error))
    finally:
        if anchor is not None:os.close(anchor)
        if directory is not None:os.close(directory)
        os.close(parent)
    return record

def verify_content(args):
    output=Path(args.output)
    if not output.is_absolute():raise Refusal('复核报告必须是内部APFS宿主的绝对路径。')
    validate_path(output.parent)
    host=os.open(output.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        host_state=probe(args.probe,output.parent);host_stat=os.fstat(host)
        if host_state.get('provider')!='apfs' or host_state.get('internal') is not True or host_state.get('read_only') is not False or (host_state.get('directory_device'),host_state.get('directory_inode'))!=(host_stat.st_dev,host_stat.st_ino):
            raise Refusal('报告父目录不是已绑定FD的内部可写APFS；不允许在测试卷写报告。')
        try:os.stat(output.name,dir_fd=host,follow_symlinks=False)
        except FileNotFoundError:pass
        else:raise Refusal('报告已存在，拒绝覆盖。')
        record=dict(schema=2,kind='content-verification',run_id=str(uuid.uuid4()),status='failed',files=[])
        try:
            source=read_owned_json(args.source_report)
            if source.get('fixture_boundary'):raise Refusal('镜像/构造边界报告不能作为正式跨驱动源报告。')
            target=Path(args.target);validate_path(target)
            before=probe(args.probe,target)
            validate_target(before,args.expect_provider,args.expect_media_id,args.expect_capacity,read_only=True)
            record=verify_owned_workset(target,source,before,args.probe,args.expect_provider,args.expect_media_id,args.expect_capacity)
        except Waiting as error:record.update(status='waiting',reason=str(error))
        except Exception as error:record.update(status='failed',reason=str(error))
        fd=os.open(output.name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=host)
        with os.fdopen(fd,'w') as f:json.dump(record,f,ensure_ascii=False,indent=2);f.write('\n')
        return record
    finally:os.close(host)

def summarize(records):
    failures=[];groups={};seen=set();seen_steps=set();completed=set();verifications=[]
    plan=make_plan();steps={s['id']:s for s in plan['steps']}
    sample_workloads=['sequential-write','sequential-read','random-write','random-read','small-files-and-sync']
    for r in records:
        if r.get('kind')=='content-verification':
            verifications.append(r)
            if r.get('status')!='passed':failures.append(r)
            continue
        if r.get('status')!='passed':failures.append(r);continue
        run_id=r.get('run_id');step_id=r.get('plan_step')
        reason=None
        if run_id and run_id in seen:reason='重复run_id，不重复计入样本'
        if step_id:
            step=steps.get(step_id)
            if not step:reason='未知计划步骤'
            elif step_id in seen_steps:reason='重复计划步骤，不重复计入样本'
            elif any(r.get(k)!=step[k] for k in ['provider','cache','workload','size_bytes','seed','concurrency']):reason='结果参数与固定计划不符'
            elif r.get('logical_write_bytes',step['write_budget_bytes']+1)>step['write_budget_bytes']:reason='结果实际写量缺失或超预算'
            elif r.get('fio_commit')!=PIN or r.get('ioengine')!=('posix' if step['workload']=='small-files-and-sync' else 'psync') or r.get('iodepth')!=1 or r.get('numjobs')!=1:
                reason='结果引擎/队列/fio提交与固定方案不符'
            elif r.get('small_file_count')!=(10000 if step['workload']=='small-files-and-sync' else 0):reason='小文件参数与固定方案不符'
            elif r.get('fixture_boundary'):reason='构造身份边界结果不能计入正式比较'
        if reason:
            failures.append(dict(status='invalid',reason=reason,run_id=run_id,plan_step=step_id));continue
        if run_id:seen.add(run_id)
        if step_id:seen_steps.add(step_id)
        parameters={k:r.get(k) for k in ['size_bytes','seed','fio_commit','ioengine','iodepth','numjobs','fio_version','concurrency','small_file_count','sync_policy']}
        signature=json.dumps(parameters,sort_keys=True)
        key=tuple(r.get(k) for k in ['workload','cache','provider'])+(signature,)
        groups.setdefault(key,[]).append(r)
        if step_id and run_id and all(v is not None for v in parameters.values()) and r.get('fio_commit')==PIN:
            completed.add(step_id)
    rows=[]
    for (workload,cache,provider,signature),values in sorted(groups.items(),key=lambda item:repr(item[0])):
        rates=[v['fio_bytes_per_second'] for v in values];median=statistics.median(rates)
        rows.append(dict(workload=workload,cache=cache,provider=provider,parameters=json.loads(signature),samples=len(values),
            plan_samples=sum(v.get('plan_step') in completed for v in values),
            median_bytes_per_second=median,minimum=min(rates),maximum=max(rates),
            median_duration_seconds=statistics.median(v.get('duration_seconds',0) for v in values),
            sync_seconds=[v.get('sync_seconds') for v in values],
            spread_fraction=(max(rates)-min(rates))/median if median else None,
            investigation_required=median==0 or (max(rates)-min(rates))/median>0.1))
    expected={(s['workload'],s['cache'],s['provider'],s['concurrency']) for s in plan['steps'] if s['workload'] in sample_workloads}
    present={(r['workload'],r['cache'],r['provider'],r['parameters']['concurrency']) for r in rows if r['plan_samples']>=6}
    missing_steps=sorted(set(steps)-completed)
    return dict(schema=2,content_verifications=verifications,complete=not failures and expected<=present and not missing_steps,groups=rows,failures=failures,
        missing_plan_steps=missing_steps,
        missing_groups=[dict(workload=w,cache=c,provider=p,concurrency=n) for w,c,p,n in sorted(expected-present)],
        limitation='不同大小、并发、fio版本、种子、同步和队列参数不合并。正式统计须各组6个不同计划样本且全部步骤覆盖；构造身份边界不算正式结果。')

def execute(args):
    output=Path(args.output);record=dict(schema=2,run_id=str(uuid.uuid4()),status='failed',fio_commit=PIN,seed=SEED,
        expected_provider=args.expect_provider)
    if output.exists():raise Refusal('报告文件已存在，拒绝覆盖。')
    token=None;ledger=None
    try:
        target=Path(args.target);validate_path(target)
        before=probe(args.probe,target);record['observed_target']=before
        validate_target(before,args.expect_provider,args.expect_media_id,args.expect_capacity)
        cache='nocache-requested' if args.direct else 'buffered'
        size=args.size_mib*MIB;budget=args.budget_mib*MIB
        workload=getattr(args,'workload','sequential-write');concurrency=getattr(args,'concurrency',1)
        count=getattr(args,'small_file_count',10000)
        plan=make_plan();step=None
        if args.step:
            step=next((s for s in plan['steps'] if s['id']==args.step),None)
            if not step:raise Refusal('计划步骤不存在。')
            if step['provider']!=args.expect_provider or step['cache']!=cache:raise Refusal('实际提供方/缓存与计划步骤不符。')
            if not getattr(args,'ledger',None):raise Refusal('正式计划必须使用累计预算账本。')
            workload=step['workload'];size=step['size_bytes'];budget=step['write_budget_bytes'];concurrency=step['concurrency'];count=10000
            record['plan_step']=step['id']
        if workload not in {s['workload'] for s in plan['steps']} or concurrency not in [1,4]:raise Refusal('负载或并发数无效。')
        if workload=='small-files-and-sync':
            if not 1<=count<=10000:raise Refusal('小文件数量超限。')
            size=count*4096
        required=0 if workload in ['sequential-read','random-read'] else (count*4096 if workload=='small-files-and-sync' else size)
        if size<=0 or size>32*GIB or budget<required:raise Refusal('大小或逻辑写入预算不足；单步上限32GiB。')
        free=os.statvfs(target).f_bavail*os.statvfs(target).f_frsize
        if free<size+20*GIB or free<args.expect_capacity/5:raise Refusal('空间不足：保留20GiB和卷容量20%。')
        manifest=json.loads(Path(args.fio_manifest).read_text());fio=Path(args.fio).resolve()
        if manifest.get('commit')!=PIN or manifest.get('binary_sha256')!=digest(fio):raise Refusal('fio固定提交/二进制摘要未匹配。')
        ledger_context=Ledger(Path(args.ledger),plan) if getattr(args,'ledger',None) else nullcontext(None)
        with ledger_context as ledger:
            dependency=None
            if step and step.get('depends_on'):
                dependency=ledger.result(step['depends_on'])
            elif getattr(args,'source_report',None):
                dependency=json.loads(Path(args.source_report).read_text())
            reuse=workload in ['sequential-read','random-write','random-read']
            if reuse:
                previous={'sequential-read':'sequential-write','random-write':'random-initialize','random-read':'random-write'}[workload]
                if not dependency or dependency.get('status')!='passed' or dependency.get('workload')!=previous:
                    raise Refusal('缺少匹配的已通过工作集前置报告。')
                for key,value in [('provider',args.expect_provider),('media_id',args.expect_media_id),('capacity',args.expect_capacity),('size_bytes',size),('cache',cache),('concurrency',concurrency),('seed',SEED)]:
                    if dependency.get(key)!=value:raise Refusal('依赖工作集参数不一致：'+key)
                basename=dependency.get('session_name','')
                if not basename.startswith('WriteFlow-Benchmark-') or Path(basename).name!=basename:raise Refusal('工作集目录名无效。')
                session=target/basename;validate_path(session)
            else:session=target/('WriteFlow-Benchmark-'+str(uuid.uuid4()))
            if ledger:
                if step is None:raise Refusal('账本仅用于固定正式计划步骤。')
                token=ledger.reserve(step)
                record['cumulative_reserved_write_bytes']=ledger.data['reserved_write_bytes']
                record['cumulative_reserved_by_cache']=dict(ledger.data['reserved_by_cache'])
            directory=None;isolation_fd=None;isolation_proof=None
            try:
                if not reuse:session.mkdir(mode=0o700)
                directory=os.open(session,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                st=os.fstat(directory)
                checked=probe(args.probe,session);validate_target(checked,args.expect_provider,args.expect_media_id,args.expect_capacity)
                if checked.get('mount_identity')!=before.get('mount_identity'):raise Refusal('挂载实例发生变化。')
                isolation_fd=open_isolation(directory,session,checked)
                if isolation_fd is not None:isolation_proof=checked['isolation']
                if reuse:
                    marker_fd=os.open('.writeflow-owner.json',os.O_RDONLY|os.O_NOFOLLOW,dir_fd=directory)
                    try:owner=json.loads(os.read(marker_fd,4096))
                    finally:os.close(marker_fd)
                    if owner.get('token')!=dependency.get('owner_token') or owner.get('schema')!=1:
                        raise Refusal('工作集缺少本工具创建的所有权标记。')
                    owner_token=owner['token']
                else:
                    owner_token=str(uuid.uuid4())
                    marker_fd=os.open('.writeflow-owner.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
                    try:
                        os.write(marker_fd,json.dumps(dict(schema=1,token=owner_token)).encode());os.fsync(marker_fd)
                    finally:os.close(marker_fd)
                checked=probe(args.probe,session);validate_target(checked,args.expect_provider,args.expect_media_id,args.expect_capacity)
                if checked.get('mount_identity')!=before.get('mount_identity'):raise Refusal('挂载实例发生变化。')
                if reuse:
                    observed=hashes(directory,list(dependency['file_hashes']))
                    # 跨重新挂载inode可能改变，摘要及长度必须逐文件一致。
                    if {k:(v['sha256'],v['size']) for k,v in observed.items()}!={k:(v['sha256'],v['size']) for k,v in dependency['file_hashes'].items()}:
                        raise Refusal('依赖工作集已被修改，拒绝继续。')
                result=small_files(directory,count,args.direct,args.timeout) if workload=='small-files-and-sync' else fio_workload(fio,directory,workload,size,concurrency,args.direct,args.timeout,not reuse)
                record.update(result)
                if result['logical_write_bytes']>budget:raise Refusal('实际逻辑写量超预算。')
                after=probe(args.probe,session);validate_target(after,args.expect_provider,args.expect_media_id,args.expect_capacity)
                if after.get('mount_identity')!=before.get('mount_identity'):raise Refusal('测试后挂载实例变化。')
                if isolation_fd is not None:
                    if after.get('isolation')!=isolation_proof:raise Refusal('执行后外层隔离证明变化。')
                    repeated=open_isolation(directory,session,after)
                    try:
                        held_stat=os.fstat(isolation_fd);fresh_stat=os.fstat(repeated)
                        if (held_stat.st_dev,held_stat.st_ino)!=(fresh_stat.st_dev,fresh_stat.st_ino):raise Refusal('持有隔离祖先与当前路径不同。')
                    finally:os.close(repeated)
                    record['isolation']=isolation_proof
                # 目录路径必须仍指向持有句柄，阻止重命名/替换后把异处结果报为成功。
                path_stat=os.stat(session,follow_symlinks=False)
                if (path_stat.st_dev,path_stat.st_ino)!=(st.st_dev,st.st_ino):raise Refusal('工作集目录被替换。')
                record.update(status='passed',provider=after['provider'],media_id=after['media_id'],capacity=after['capacity'],
                    mount_identity=after['mount_identity'],workload=workload,cache=cache,size_bytes=size,concurrency=concurrency,
                    budget_bytes=budget,session_directory=str(session),session_name=session.name,owner_token=owner_token,small_file_count=count if workload=='small-files-and-sync' else 0,
                    sha256=hashlib.sha256(json.dumps(result['file_hashes'],sort_keys=True).encode()).hexdigest(),
                    limitations=['单步通过不代表完整ABBA比较','F_NOCACHE请求不代表冷缓存','未验证Windows/掉电安全'])
            except Waiting as error:record.update(status='waiting',reason=str(error))
            except Exception as error:record.update(status='failed',reason=str(error))
            finally:
                if isolation_fd is not None:os.close(isolation_fd)
                if directory is not None:os.close(directory)
                if token:ledger.finish(token,record)
    except Waiting as error:record.update(status='waiting',reason=str(error))
    except Exception as error:record.update(status='failed',reason=str(error))
    with output.open('x') as f:json.dump(record,f,ensure_ascii=False,indent=2);f.write('\n')
    return record

def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='action',required=True)
    p=commands.add_parser('plan');p.add_argument('--output',required=True)
    r=commands.add_parser('run')
    for flag in ['target','probe','fio','fio-manifest','expect-provider','output']:r.add_argument('--'+flag,required=True)
    r.add_argument('--expect-media-id',type=int,required=True);r.add_argument('--expect-capacity',type=int,required=True)
    r.add_argument('--size-mib',type=int,default=4);r.add_argument('--budget-mib',type=int,default=4)
    r.add_argument('--workload',default='sequential-write');r.add_argument('--concurrency',type=int,default=1)
    r.add_argument('--ledger');r.add_argument('--source-report');r.add_argument('--small-file-count',type=int,default=256)
    r.add_argument('--direct',action='store_true');r.add_argument('--step');r.add_argument('--timeout',type=int,default=120)
    v=commands.add_parser('verify')
    for flag in ['source-report','target','probe','expect-provider','output']:v.add_argument('--'+flag,required=True)
    v.add_argument('--expect-media-id',type=int,required=True);v.add_argument('--expect-capacity',type=int,required=True)
    p=commands.add_parser('report');p.add_argument('inputs',nargs='+');p.add_argument('--output',required=True)
    args=parser.parse_args()
    if args.action in ['run','verify']:
        result=execute(args) if args.action=='run' else verify_content(args);print(result['status']);raise SystemExit(0 if result['status']=='passed' else 2)
    result=make_plan() if args.action=='plan' else summarize([json.loads(Path(p).read_text()) for p in args.inputs])
    with Path(args.output).open('x') as f:json.dump(result,f,ensure_ascii=False,indent=2);f.write('\n')
if __name__=='__main__':main()
