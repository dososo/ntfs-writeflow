#!/usr/bin/env python3
"""真实产品会话验收：默认只读；arm/disarm仅修改固定专用诊断键。"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

DOMAIN='com.blteam.ntfsworkbench'
KEY='writeflow.sessionVerification'
PREFIX='WF_SESSION '
EVENTS={'即将完成启动','启动完成','启动窗口采样','会话窗口采样','磁盘监控启动完成','重新打开','会话信号','主动确认请求','正常退出',
        '请求挂载','请求自动挂载','请求卸载','请求弹出','登录设置变化'}
SIGNALS={'foreground','workspaceResigned','workspaceActive','willSleep','didWake','protectedDataUnavailable',
         'protectedDataAvailable','screenLocked','screenUnlocked'}
BOOL_FIELDS={'登录项已启用','自动管理','前台确认','待确认','工作区活动','数据保护','数据保护闭锁','睡眠闭锁',
             '控制台当前用户','应用活动','磁盘监控存在','会话监控存在'}
INT_FIELDS={'格式','序号','PID','UID','EUID','撤销代数','激活策略','可见内容窗数','最小化内容窗数'}
FIELDS=BOOL_FIELDS|INT_FIELDS|{'验收编号','进程会话','事件','时间','应用标识','版本','构建','主程序SHA256','原始事件ID',
    '原始启动原因','登录启动','登录项状态','控制台UID','调用进程会话UID','调用会话在控制台','内容窗角色','采样秒数','信号'}
LOGIN_STATES={'尚未查询','已启用','等待在系统设置批准','未启用','系统未找到当前应用','系统返回未知状态'}
OPERATIONS={'请求挂载','请求自动挂载','请求卸载','请求弹出'}
ROOT=Path(__file__).resolve().parents[2]

class EvidenceIncomplete(ValueError): pass
class SafetyFailure(ValueError): pass

def strict_json(data):
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise ValueError('JSON含重复键')
            result[key]=value
        return result
    return json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('JSON含非有限数')))

def canonical(value):
    try:return type(value) is str and str(uuid.UUID(value)).upper()==value
    except (ValueError,AttributeError):return False

def valid_config(value,now):
    if not isinstance(value,dict) or set(value)!={'版本','编号','创建时间','到期时间'}:return False
    if type(value['版本']) not in (int,float) or value['版本']!=1 or not canonical(value['编号']):return False
    for key in ('创建时间','到期时间'):
        if type(value[key]) not in (int,float) or not math.isfinite(value[key]):return False
    return 0<=value['创建时间']<=now<value['到期时间'] and value['到期时间']-value['创建时间']<=21600

def freeze_value(value):
    return {'存在':value is not None,'值Base64':base64.b64encode(plistlib.dumps(value,fmt=plistlib.FMT_BINARY)).decode() if value is not None else None}

def thaw_value(snapshot):
    if not isinstance(snapshot,dict) or set(snapshot)!={'存在','值Base64'} or type(snapshot['存在']) is not bool:
        raise ValueError('偏好快照结构不符')
    if not snapshot['存在']:
        if snapshot['值Base64'] is not None:raise ValueError('空快照含数据')
        return None
    encoded=snapshot['值Base64']
    if not isinstance(encoded,str):raise ValueError('偏好备份格式不符')
    data=base64.b64decode(encoded,validate=True)
    if len(data)>32768:raise ValueError('偏好备份超限')
    return plistlib.loads(data)

def same_value(a,b):
    if type(a) is not type(b):return False
    if isinstance(a,dict):return set(a)==set(b) and all(same_value(a[k],b[k]) for k in a)
    if isinstance(a,list):return len(a)==len(b) and all(same_value(x,y) for x,y in zip(a,b))
    return a==b

def check_row(outer,plan):
    if not isinstance(outer,dict) or not isinstance(outer.get('eventMessage'),str):raise EvidenceIncomplete('统一日志外层格式未知')
    message=outer['eventMessage']
    if not message.startswith(PREFIX):raise EvidenceIncomplete('统一日志前缀不符或已脱敏')
    try:r=strict_json(message[len(PREFIX):])
    except (ValueError,TypeError) as e:raise EvidenceIncomplete('日志JSON缺失、脱敏或损坏') from e
    if not isinstance(r,dict) or set(r)!=FIELDS:raise EvidenceIncomplete('日志固定字段缺失或未知')
    if outer.get('subsystem')!=DOMAIN or outer.get('category')!='SessionVerification':raise EvidenceIncomplete('统一日志来源类别不符')
    if type(outer.get('processID')) is not int or outer['processID']!=r['PID'] or outer.get('processImagePath')!=plan['安装身份']['主程序路径']:
        raise EvidenceIncomplete('拒绝自报身份：外层PID/真实进程路径不属于稳定产品')
    if r['验收编号']!=plan['配置']['编号'] or not canonical(r['进程会话']):raise EvidenceIncomplete('混入其他验收或进程会话标识未知')
    if any(type(r[k]) is not bool for k in BOOL_FIELDS) or any(type(r[k]) is not int or r[k]<0 for k in INT_FIELDS):
        raise EvidenceIncomplete('日志布尔或整数类型不符')
    if r['格式']!=2 or r['序号']<1 or r['序号']>256 or r['PID']<=1 or r['激活策略'] not in (0,1,2):raise EvidenceIncomplete('日志版本/序号/激活策略未知')
    if type(r['事件']) is not str or type(r['登录项状态']) is not str or r['事件'] not in EVENTS or r['登录项状态'] not in LOGIN_STATES:raise EvidenceIncomplete('事件或登录项状态未知')
    if r['登录项状态'] in {'尚未查询','系统返回未知状态'}:raise EvidenceIncomplete('产品登录项状态尚未知')
    if r['登录项已启用']!=(r['登录项状态']=='已启用'):raise EvidenceIncomplete('登录项状态和启用标记矛盾')
    if r['UID']!=plan['UID'] or r['EUID']!=plan['UID']:raise EvidenceIncomplete('日志不属于本用户，禁止跨用户取证')
    identity=plan['安装身份']
    if (r['应用标识']!=DOMAIN or r['版本']!=identity['版本'] or r['构建']!=identity['构建']
            or r['主程序SHA256']!=identity['主程序SHA256']):raise EvidenceIncomplete('日志版本/主程序摘要与安装预检不一致')
    for k in ('原始事件ID','原始启动原因','控制台UID','调用进程会话UID'):
        if r[k] is not None and (type(r[k]) is not int or not 0<=r[k]<=0xffffffff):raise EvidenceIncomplete('可空UInt32字段不符')
    if r['登录启动'] is not None and type(r['登录启动']) is not bool:raise EvidenceIncomplete('登录分类不是可空布尔')
    if r['调用会话在控制台'] is not None and type(r['调用会话在控制台']) is not bool:raise EvidenceIncomplete('调用会话控制台标记不是可空布尔')
    if r['事件']=='会话信号':
        if type(r['信号']) is not str or r['信号'] not in SIGNALS:raise EvidenceIncomplete('会话信号未知')
    elif r['事件']=='会话窗口采样':
        if r['信号'] not in ('workspaceResigned','workspaceActive'):raise EvidenceIncomplete('会话采样信号未知')
    elif r['信号'] is not None:raise EvidenceIncomplete('非信号事件含未知信号')
    if r['事件'] in ('启动窗口采样','会话窗口采样'):
        if type(r['采样秒数']) is not int or r['采样秒数'] not in (1,3,8):raise EvidenceIncomplete('窗口采样秒数未知')
    elif r['采样秒数'] is not None:raise EvidenceIncomplete('非采样事件含采样秒数')
    roles=r['内容窗角色']
    if not isinstance(roles,list) or any(type(x) is not str or x not in {'主窗口','诊断','设置','其他'} for x in roles) or len(roles)!=r['可见内容窗数']:
        raise EvidenceIncomplete('可见窗口角色与数量不符')
    try:stamp=datetime.fromisoformat(r['时间'].replace('Z','+00:00'))
    except (ValueError,AttributeError,TypeError) as e:raise EvidenceIncomplete('UTC时间不可解析') from e
    if stamp.tzinfo is None or stamp.utcoffset().total_seconds()!=0:raise EvidenceIncomplete('日志时间不是UTC')
    if not math.floor(plan['配置']['创建时间'])<=stamp.timestamp()<plan['配置']['到期时间']:raise EvidenceIncomplete('日志不在本轮有效期限内')
    if r['自动管理'] or r['事件'] in OPERATIONS:raise SafetyFailure('自动管理开启或观察到磁盘操作请求，安全验收未通过')
    return r

def assess(rows,plan):
    if not rows:raise EvidenceIncomplete('没有本轮产品日志；不能将没有日志当作通过')
    parsed=[check_row(row,plan) for row in rows]
    groups={}
    for row in parsed:groups.setdefault(row['进程会话'],[]).append(row)
    login=[];workspaces=[];ordinary=[];console_candidates=[]
    for session,events in groups.items():
        events.sort(key=lambda r:r['序号'])
        if [r['序号'] for r in events]!=list(range(1,len(events)+1)):raise EvidenceIncomplete('序号重复/缺行或日志截断')
        if events[0]['事件']!='即将完成启动' or events[-1]['事件']!='正常退出':raise EvidenceIncomplete('缺少完整启动/正常退出清理尾，不能推断清理')
        if len({(r['PID'],r['UID'],r['EUID']) for r in events})!=1:raise EvidenceIncomplete('同进程会话的外层身份混合')
        finishes=[r for r in events if r['事件']=='启动完成']
        if len(finishes)!=1:raise EvidenceIncomplete('启动完成记录缺失或重复')
        first=finishes[0];context=tuple(first[k] for k in ('原始事件ID','原始启动原因','登录启动'))
        if first['登录启动'] is None:raise EvidenceIncomplete('启动完成没有真实启动分类')
        expected=(first['原始事件ID']==0x6f617070 and first['原始启动原因']==0x6c676974)
        if first['登录启动']!=expected:raise EvidenceIncomplete('原始AppleEvent与产品分类矛盾')
        if any(tuple(r[k] for k in ('原始事件ID','原始启动原因','登录启动'))!=context for r in events if r['序号']>=first['序号']):
            raise EvidenceIncomplete('同进程后续启动上下文未保持一致')
        samples=[r for r in events if r['事件']=='启动窗口采样']
        if [r['采样秒数'] for r in samples]!=[1,3,8]:raise EvidenceIncomplete('缺少按顺序的1/3/8秒完整窗口采样')
        tail=events[-1]
        if tail['磁盘监控存在'] or tail['会话监控存在'] or tail['前台确认'] or tail['待确认']:
            raise SafetyFailure('正常退出记录未完成监控与确认清理')
        if first['登录启动']:
            if not first['登录项已启用']:raise SafetyFailure('真实登录启动时SMAppService未确认启用')
            startup=[r for r in events if r['序号']<=samples[-1]['序号']]
            if any(r['前台确认'] or r['待确认'] or r['应用活动'] or r['可见内容窗数']!=0 or r['最小化内容窗数']!=0
                   or (r['序号']>=first['序号'] and r['激活策略']!=1) for r in startup):
                raise SafetyFailure('真实登录后台阶段存在确认请求、激活或内容窗')
            if any(r['事件'] in {'重新打开','主动确认请求'} for r in events if first['序号']<=r['序号']<=max(x['序号'] for x in samples)):
                raise EvidenceIncomplete('启动8秒窗口采样完成前发生主动操作，无法隔离后台启动行为')
            login.append(session)
        elif all(r['激活策略']==0 and r['可见内容窗数']==1 and r['最小化内容窗数']==0
                 and r['内容窗角色']==['主窗口'] for r in samples):
            ordinary.append(session)
        resigned=[r for r in events if r['事件']=='会话信号' and r['信号']=='workspaceResigned']
        active=[r for r in events if r['事件']=='会话信号' and r['信号']=='workspaceActive']
        for inactive in resigned:
            returned=next((r for r in active if r['序号']>inactive['序号']),None)
            if returned is None:continue
            next_resign=next((r['序号'] for r in resigned if r['序号']>returned['序号']),events[-1]['序号'])
            next_request=next((r['序号'] for r in events if r['序号']>returned['序号'] and r['事件']=='主动确认请求'),events[-1]['序号'])
            revoked=[r for r in events if inactive['序号']<=r['序号']<=returned['序号']
                     or returned['序号']<r['序号']<min(next_resign,next_request)]
            if inactive['工作区活动'] or any(r['前台确认'] or r['待确认'] for r in revoked):
                raise SafetyFailure('真实用户会话离开/返回时未撤销确认')
            workspaces.append(session)
            away=[r for r in events if inactive['序号']<r['序号']<returned['序号']
                  and r['事件']=='会话窗口采样' and r['信号']=='workspaceResigned']
            back=[r for r in events if returned['序号']<r['序号']<next_resign
                  and r['事件']=='会话窗口采样' and r['信号']=='workspaceActive']
            if [r['采样秒数'] for r in away]==[1,3,8] and [r['采样秒数'] for r in back]==[1,3,8]:
                b=away[0]['控制台UID'];a=plan['UID']
                if (type(b) is int and b>=501 and b!=a
                    and all(r['控制台UID']==b and r['调用进程会话UID']==a and r['调用会话在控制台'] is False
                            and not r['工作区活动'] and not r['前台确认'] and not r['待确认'] for r in away)
                    and all(r['控制台UID']==a and r['调用进程会话UID']==a and r['调用会话在控制台'] is True
                            and r['工作区活动'] and not r['前台确认'] and not r['待确认'] for r in back)):
                    console_candidates.append({'进程会话':session,'原UID':a,'稳定异UID':b,'离开序号':inactive['序号'],'返回序号':returned['序号']})
    scenario=plan['场景']
    passed={'真实登录':bool(login),'切换用户':False,'普通对照':bool(ordinary)}[scenario]
    return {'判定':'通过' if passed else '证据不足','范围':scenario,'日志来源及完整生命周期':'通过',
        '普通冷启动对照':'通过' if ordinary else '待测','真实登录':'通过' if login else '待测','真实切换用户':'待测',
        '工作区离开返回':'通过' if workspaces else '待测','稳定异UID控制台候选':console_candidates,
        '跨账户桌面人工确认':'待用户独立确认，CLI不自动授予通过',
        '进程会话数':len(groups),'普通对照会话':ordinary,'真实登录会话':login,'工作区离开返回会话':workspaces,'有效记录数':len(parsed)}

def save_json(path,value):
    path=Path(path)
    if path.exists():
        if path.is_symlink() or path.stat().st_uid!=os.geteuid():raise ValueError('证据文件身份不符')
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
    else:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as f:json.dump(value,f,ensure_ascii=False,indent=2,allow_nan=False);f.write('\n')

def save_bytes(path,data):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(data or b'')

class Commands:
    def __init__(self,folder):self.folder=folder;self.records=[]
    def __call__(self,args,input_data=None,keep=True,timeout=45):
        number=len(self.records)+1
        try:response=subprocess.run(list(map(str,args)),input=input_data,capture_output=True,timeout=timeout)
        except subprocess.TimeoutExpired as error:
            if keep:save_bytes(self.folder/f'命令-{number:03d}.输出',error.stdout)
            save_bytes(self.folder/f'命令-{number:03d}.错误',error.stderr)
            self.records.append({'参数':list(map(str,args)),'退出码':None,'超时秒数':timeout,'标准输出保留':keep})
            save_json(self.folder/'命令.json',self.records);raise
        if keep:save_bytes(self.folder/f'命令-{number:03d}.输出',response.stdout)
        save_bytes(self.folder/f'命令-{number:03d}.错误',response.stderr)
        self.records.append({'参数':list(map(str,args)),'退出码':response.returncode,'标准输出保留':keep})
        save_json(self.folder/'命令.json',self.records)
        if response.returncode:raise ValueError('本轮命令未通过：'+str(args[0]))
        return response.stdout

def preference_tool(folder,run):
    source=Path(__file__).with_name('会话验收偏好.swift');target=folder/'固定单键偏好工具'
    run(['xcrun','swiftc','-swift-version','6','-warnings-as-errors',source,'-o',target])
    save_json(folder/'偏好工具来源.json',{'源码SHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
        '工具SHA256':hashlib.sha256(target.read_bytes()).hexdigest(),'域':DOMAIN,'唯一键':KEY})
    return target

def preflight(app,tool,run):
    app=Path(app).expanduser()
    if app.is_symlink() or not app.is_dir():raise ValueError('稳定安装应用不存在或为链接')
    app=app.resolve();info_path=app/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier')!=DOMAIN or info.get('CFBundleExecutable')!='NTFSWorkbench':raise ValueError('不是预期的正式产品标识/可执行')
    executable=app/'Contents/MacOS/NTFSWorkbench'
    if not executable.is_file() or executable.is_symlink():raise ValueError('安装主程序身份不符')
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    signature=run(['/usr/bin/codesign','-d','--verbose=4',app])
    prefs=json.loads(run([tool,'read']))
    thaw_value(prefs['专用键'])
    disks=plistlib.loads(run(['/usr/sbin/diskutil','list','-plist'],keep=False)).get('AllDisks')
    if not isinstance(disks,list) or any(not isinstance(d,str) or not re.fullmatch(r'disk[0-9]+(?:s[0-9]+)*',d) for d in disks):
        raise ValueError('磁盘元数据清单格式未知')
    ntfs=[];unknown=[]
    for device in disks:
        meta=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',device],keep=False))
        fields=[str(meta.get(k,'')) for k in ('FilesystemType','FilesystemName','FilesystemUserVisibleName','FilesystemPersonality','TypeBundleIdentifier','Content')]
        if any('ntfs' in value.lower() for value in fields):ntfs.append(device)
        if meta.get('Content') in ('Microsoft Basic Data','Microsoft_Basic_Data') and not meta.get('FilesystemType'):unknown.append(device)
    mounts=run(['/sbin/mount'],keep=False).decode(errors='strict')
    blntfs=bool(re.search(r'\(blntfs(?:,|\))',mounts,re.I))
    processes=run(['/bin/ps','-axo','pid=,comm='],keep=False).decode(errors='strict')
    pids=[]
    for line in processes.splitlines():
        parts=line.strip().split(None,1)
        if len(parts)==2 and parts[0].isdigit() and Path(parts[1]).name=='NTFSWorkbench':pids.append(int(parts[0]))
    identity={'应用路径':str(app),'主程序路径':str(executable),'应用标识':DOMAIN,'版本':info.get('CFBundleShortVersionString'),
        '构建':info.get('CFBundleVersion'),'主程序SHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),
        'InfoPlistSHA256':hashlib.sha256(info_path.read_bytes()).hexdigest(),
        '签名封套SHA256':hashlib.sha256((app/'Contents/_CodeSignature/CodeResources').read_bytes()).hexdigest()}
    if any(not isinstance(identity[k],str) or not identity[k] for k in ('版本','构建')):raise ValueError('安装版本未知')
    safe=prefs.get('自动管理')=='关闭' and prefs.get('专用键遮蔽') is False and not ntfs and not unknown and not blntfs
    return {'安装身份':identity,'偏好':prefs,'安全基线通过':safe,'NTFS设备':ntfs,'未知Microsoft数据分区':unknown,
        '存在blntfs挂载':blntfs,'产品运行PID':pids,'登录项状态':'由真实产品原生日志核验，CLI不猜测或登记',
        '范围':'执行真实只读元数据查询；不读取用户文件、不发送挂载/卸载/弹出，不登记服务'}

def load_plan(path):
    path=Path(path).expanduser()
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
    with os.fdopen(fd,'r') as file:
        info=os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077 or info.st_nlink!=1 or info.st_size>1024*1024:
            raise ValueError('计划必须为当前用户私有、有界普通文件')
        plan=strict_json(file.read(1024*1024+1))
    if plan.get('格式')!=1 or plan.get('UID')!=os.geteuid() or not canonical(plan.get('配置',{}).get('编号')):
        raise ValueError('计划身份或格式不符')
    thaw_value(plan['原专用键'])
    return plan

def same_identity(before,after):return before==after

def main():
    parser=argparse.ArgumentParser(description='真实产品会话验收；默认仅预检，不登记登录项或操作账户/磁盘。')
    parser.add_argument('action',nargs='?',choices=['preflight','plan','arm','collect','disarm'],default='preflight')
    parser.add_argument('--app',default=str(Path.home()/'Applications/NTFSWriteFlow.app'),help='只读核验的稳定安装应用')
    parser.add_argument('--plan',help='本轮私有计划文件；arm/collect/disarm必须明确指定')
    parser.add_argument('--duration',type=int,default=3600,help='计划有效秒数，最多21600；不会触发注销或登录')
    parser.add_argument('--scenario',choices=['login','switch','ordinary'],default='login',help='计划目标：真实登录、切用户或普通对照')
    parser.add_argument('--mode',choices=['login','switch','ordinary'],help='collect显式验收范围；普通对照不替代真实登录')
    args=parser.parse_args()
    if os.geteuid()==0:parser.error('禁止sudo；仅核验当前用户的正式产品')
    if args.action in ('arm','collect','disarm') and not args.plan:parser.error('此命令必须提供--plan；没有默认写入目标')
    base=Path.home()/'Library/Application Support/NTFSWriteFlow/会话验收';base.mkdir(parents=True,exist_ok=True)
    folder=Path(tempfile.mkdtemp(prefix=args.action+'-',dir=base));run=Commands(folder)
    result={'命令':args.action,'结果':'进行中','证据目录':str(folder),'偏好写入':False}
    try:
        tool=preference_tool(folder,run)
        scenarios={'login':'真实登录','switch':'切换用户','ordinary':'普通对照'}
        if args.action in ('preflight','plan'):
            inspection=preflight(args.app,tool,run);save_json(folder/'预检.json',inspection)
            result['安全基线通过']=inspection['安全基线通过'];result['产品运行PID']=inspection['产品运行PID']
            if args.action=='plan':
                if not inspection['安全基线通过']:raise SafetyFailure('安全基线未通过；不生成可arm计划，不自动改开关或磁盘')
                if not 1<=args.duration<=21600:raise ValueError('计划期限必须为1至21600秒')
                created=float(math.floor(time.time()))
                plan={'格式':1,'UID':os.geteuid(),'场景':scenarios[args.scenario],'安装身份':inspection['安装身份'],
                    '原专用键':inspection['偏好']['专用键'],'配置':{'版本':1,'编号':str(uuid.uuid4()).upper(),'创建时间':created,'到期时间':created+args.duration},
                    'CLI源码SHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
                save_json(folder/'计划.json',plan);result['计划']=str(folder/'计划.json')
                result['下一步']='先正常退出真实产品，协调部署后显式arm；CLI不会退出应用或登记登录项。'
            result['结果']='只读检查完成' if inspection['安全基线通过'] else '预检未通过'
        elif args.action=='disarm':
            plan=load_plan(args.plan)
            prefs=strict_json(run([tool,'read']));current=prefs['专用键']
            if prefs.get('专用键遮蔽') is not False:raise ValueError('有效验收键被其他来源遮蔽，拒绝修改任何域')
            if not same_value(thaw_value(current),plan['配置']):raise ValueError('当前专用键不是本轮原值；拒绝覆盖后续变更')
            response=strict_json(run([tool,'restore'],input_data=json.dumps({'旧值':current,'新值':plan['原专用键']}).encode()))
            if not same_value(thaw_value(response['专用键']),thaw_value(plan['原专用键'])):raise ValueError('原专用键恢复复读不符')
            result.update(结果='本轮专用键已恢复原值',偏好写入=True)
        else:
            plan=load_plan(args.plan);inspection=preflight(plan['安装身份']['应用路径'],tool,run);save_json(folder/'预检.json',inspection)
            if not same_identity(plan['安装身份'],inspection['安装身份']):raise EvidenceIncomplete('安装身份已改变；重新生成计划，不复用旧hash')
            current=inspection['偏好']['专用键']
            if args.action=='arm':
                if not inspection['安全基线通过']:raise SafetyFailure('arm前安全基线不符；拒绝自动修正')
                if inspection['产品运行PID']:raise SafetyFailure('真实产品仍运行；请用户正常退出，CLI不代为退出')
                if not valid_config(plan['配置'],time.time()):raise ValueError('计划已失效或期限/类型不符，请重新plan')
                if not same_value(thaw_value(current),thaw_value(plan['原专用键'])):raise ValueError('原验收键已变化，拒绝覆盖')
                payload={'旧值':current,'新值':freeze_value(plan['配置'])}
                response=json.loads(run([tool,'arm'],input_data=json.dumps(payload).encode()))
                if not same_value(thaw_value(response['专用键']),plan['配置']):raise ValueError('arm写回校验不符')
                result.update(结果='已arm，仅开启限时日志',偏好写入=True,验收编号=plan['配置']['编号'])
            else:
                if not inspection['安全基线通过']:raise SafetyFailure('收集时安全基线已变化；保留证据，不通过')
                start=datetime.fromtimestamp(plan['配置']['创建时间'],timezone.utc).strftime('%Y-%m-%d %H:%M:%S+0000')
                predicate='subsystem == "com.blteam.ntfsworkbench" AND category == "SessionVerification" AND eventMessage BEGINSWITH "WF_SESSION "'
                try:raw=run(['/usr/bin/log','show','--style','json','--info','--debug','--start',start,'--predicate',predicate],timeout=45)
                except (ValueError,subprocess.TimeoutExpired) as e:raise EvidenceIncomplete('统一日志查询失败或超时，不能推断没有事件') from e
                try:rows=strict_json(raw)
                except ValueError as e:raise EvidenceIncomplete('log show不是可解析JSON或记录不可见') from e
                if not isinstance(rows,list):raise EvidenceIncomplete('log show顶层不是记录数组')
                selected=dict(plan)
                if args.mode:selected['场景']=scenarios[args.mode]
                outcome=assess(rows,selected);result.update(结果=outcome['判定'],分层验收=outcome)
                result['范围说明']='普通对照只证明普通冷启动链；真实登录、真实切用户分别判定，未发生不算通过。'
    except EvidenceIncomplete as error:result.update(结果='证据不足',原因=str(error))
    except SafetyFailure as error:result.update(结果='未通过',原因=str(error))
    except Exception as error:result.update(结果='未通过',原因=str(error))
    save_json(folder/'结果.json',result);print(json.dumps(result,ensure_ascii=False,indent=2))
    return 78 if result['结果']=='证据不足' else (1 if result['结果'] in {'未通过','预检未通过'} else 0)

if __name__=='__main__':sys.exit(main())
