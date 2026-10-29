"""不写产品偏好、不启动应用、不访问设备；日志夹具不构成真实登录通过。"""
import copy
from datetime import datetime,timezone
import importlib.util
import json
from pathlib import Path
import unittest
import uuid
import contextlib
import io
import os
import tempfile
import subprocess
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('session_cli',Path(__file__).with_name('会话验收准备.py'))
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
RUN='A75497DE-E538-4E8E-800A-98204A608548'
SESSION='3A88F35F-DBA0-47C3-871E-03E953C39514'

def test_directory():
    parent=p.ROOT/'build/0.2.0/会话CLI开发';parent.mkdir(parents=True,exist_ok=True);return parent

def plan(scenario='真实登录'):
    return {'UID':501,'场景':scenario,'配置':{'版本':1,'编号':RUN,'创建时间':1800000000.5,'到期时间':1800003600.5},
        '安装身份':{'主程序路径':'/测试/NTFSWriteFlow.app/Contents/MacOS/NTFSWorkbench','版本':'0.2.0','构建':'4','主程序SHA256':'d'*64}}

def record(event,seq,login=True):
    row={k:False for k in p.BOOL_FIELDS};row.update({k:0 for k in p.INT_FIELDS})
    row.update({'格式':2,'验收编号':RUN,'进程会话':SESSION,'序号':seq,'事件':event,
        '时间':datetime.fromtimestamp(1800000000+seq,timezone.utc).isoformat().replace('+00:00','Z'),
        'PID':1234,'UID':501,'EUID':501,'应用标识':p.DOMAIN,'版本':'0.2.0','构建':'4','主程序SHA256':'d'*64,
        '原始事件ID':0x6f617070,'原始启动原因':0x6c676974 if login else None,'登录启动':login,
        '登录项状态':'已启用','登录项已启用':True,'控制台UID':501,'调用进程会话UID':501,'调用会话在控制台':True,
        '内容窗角色':[],'采样秒数':None,'信号':None,
        '工作区活动':True,'数据保护':True,'控制台当前用户':True,'会话监控存在':True,'激活策略':1 if login else 0})
    if event=='即将完成启动':row.update(原始事件ID=None,原始启动原因=None,登录启动=None)
    if event=='正常退出':row.update(磁盘监控存在=False,会话监控存在=False)
    return row

def wrap(row):
    return {'subsystem':p.DOMAIN,'category':'SessionVerification','processID':row['PID'],
        'processImagePath':plan()['安装身份']['主程序路径'],'eventMessage':p.PREFIX+json.dumps(row,ensure_ascii=False)}

def fixture(login=True):
    rows=[record('即将完成启动',1,login),record('启动完成',2,login),record('磁盘监控启动完成',3,login)]
    for seq,second in enumerate([1,3,8],4):
        row=record('启动窗口采样',seq,login);row['采样秒数']=second
        if not login:row.update(可见内容窗数=1,内容窗角色=['主窗口'])
        rows.append(row)
    rows.append(record('正常退出',7,login))
    return list(map(wrap,rows))

class Configuration(unittest.TestCase):
    def test_exact_config_and_expiry(self):
        value=plan()['配置'];self.assertTrue(p.valid_config(value,1800000100))
        for mutation in [dict(value,版本=True),dict(value,创建时间=True),dict(value,到期时间=float('inf')),
                         dict(value,创建时间=float('nan')),dict(value,编号=RUN.lower()),dict(value,额外=1),
                         dict(value,到期时间=1800000000),dict(value,到期时间=1800021602)]:
            self.assertFalse(p.valid_config(mutation,1800000100))
    def test_snapshot_preserves_absence_and_plist_types(self):
        for value in [None,{'版本':True,'日期':[1,1.5,b'proof']},plan()['配置']]:
            self.assertEqual(p.thaw_value(p.freeze_value(value)),value)
        self.assertRaises(ValueError,p.thaw_value,{'存在':False,'值Base64':'unexpected'})
    def test_changed_boolean_is_not_equal_to_numeric_backup(self):
        self.assertFalse(p.same_value({'版本':1},{'版本':True}))
        self.assertFalse(p.same_value({'列表':[0]},{'列表':[False]}))
        self.assertTrue(p.same_value(plan()['配置'],copy.deepcopy(plan()['配置'])))
    def test_plan_read_refuses_links_and_nonprivate_files(self):
        folder=Path(tempfile.mkdtemp(prefix='计划私有边界-',dir=test_directory()));path=folder/'计划.json'
        value=plan();value.update(格式=1,UID=os.geteuid(),原专用键=p.freeze_value(None));p.save_json(path,value)
        self.assertEqual(p.load_plan(path)['UID'],os.geteuid())
        link=folder/'链接.json';link.symlink_to(path)
        self.assertRaises(OSError,p.load_plan,link)
        path.chmod(0o644);self.assertRaises(ValueError,p.load_plan,path)
    def test_command_timeout_keeps_private_partial_evidence(self):
        folder=Path(tempfile.mkdtemp(prefix='命令超时-',dir=test_directory()));run=p.Commands(folder)
        with patch.object(p.subprocess,'run',side_effect=subprocess.TimeoutExpired(['假命令'],45,output=b'partial',stderr=b'failed')) as command:
            self.assertRaises(subprocess.TimeoutExpired,run,['假命令'])
        self.assertEqual(command.call_args.kwargs['timeout'],45)
        self.assertEqual((folder/'命令-001.输出').read_bytes(),b'partial')
        self.assertEqual((folder/'命令-001.输出').stat().st_mode&0o777,0o600)
        self.assertTrue(run.records[0]['退出码'] is None)

class Evidence(unittest.TestCase):
    def test_workspace_pair_is_not_cross_account_proof(self):
        rows=fixture(False)[:-1]
        left=record('会话信号',7,False);left.update(信号='workspaceResigned',工作区活动=False,控制台当前用户=False)
        right=record('会话信号',8,False);right['信号']='workspaceActive'
        rows += [wrap(left),wrap(right),wrap(record('正常退出',9,False))]
        result=p.assess(rows,plan('切换用户'))
        self.assertEqual(result['判定'],'证据不足');self.assertEqual(result['真实切换用户'],'待测')
    def test_recorded_positive_between_startup_samples_is_failure(self):
        rows=fixture();insert=record('会话信号',5);insert.update(信号='foreground',应用活动=True,可见内容窗数=1,内容窗角色=['主窗口'])
        decoded=[json.loads(r['eventMessage'][len(p.PREFIX):]) for r in rows]
        decoded.insert(4,insert)
        for seq,row in enumerate(decoded,1):row['序号']=seq
        self.assertRaises(p.SafetyFailure,p.assess,list(map(wrap,decoded)),plan())
    def test_recorded_grants_between_workspace_endpoints_or_before_request_fail(self):
        for stage in ['失活中间','返回以后']:
            for field in ['前台确认','待确认']:
                rows=fixture(False)[:-1]
                left=record('会话信号',7,False);left.update(信号='workspaceResigned',工作区活动=False)
                right=record('会话信号',8 if stage=='返回以后' else 9,False);right['信号']='workspaceActive'
                middle=record('会话信号',9 if stage=='返回以后' else 8,False);middle['信号']='foreground';middle[field]=True
                rows += [wrap(left),*map(wrap,[right,middle] if stage=='返回以后' else [middle,right]),wrap(record('正常退出',10,False))]
                self.assertRaises(p.SafetyFailure,p.assess,rows,plan('切换用户'))
    def test_explicit_request_after_return_is_not_automatic_regrant(self):
        rows=fixture(False)[:-1]
        left=record('会话信号',7,False);left.update(信号='workspaceResigned',工作区活动=False)
        right=record('会话信号',8,False);right['信号']='workspaceActive'
        request=record('主动确认请求',9,False);request['前台确认']=True
        rows += list(map(wrap,[left,right,request,record('正常退出',10,False)]))
        self.assertEqual(p.assess(rows,plan('切换用户'))['工作区离开返回'],'通过')
    def test_will_finish_regular_policy_is_not_a_false_positive(self):
        rows=fixture();row=record('即将完成启动',1);row['激活策略']=0;rows[0]=wrap(row)
        self.assertEqual(p.assess(rows,plan())['判定'],'通过')
        row['前台确认']=True;rows[0]=wrap(row)
        self.assertRaises(p.SafetyFailure,p.assess,rows,plan())
    def test_format_two_and_nullable_caller_session_fields(self):
        self.assertEqual(len(p.FIELDS),39)
        rows=fixture();row=record('即将完成启动',1);row.update(调用进程会话UID=None,调用会话在控制台=None);rows[0]=wrap(row)
        self.assertEqual(p.assess(rows,plan())['判定'],'通过')
        row['格式']=1;rows[0]=wrap(row)
        self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_stable_console_b_is_only_candidate_not_account_acceptance(self):
        def scenario(b):
            decoded=[json.loads(r['eventMessage'][len(p.PREFIX):]) for r in fixture(False)[:-1]]
            left=record('会话信号',7,False);left.update(信号='workspaceResigned',工作区活动=False,调用会话在控制台=False,控制台当前用户=False)
            decoded.append(left)
            for seq,second in enumerate([1,3,8],8):
                row=record('会话窗口采样',seq,False);row.update(信号='workspaceResigned',采样秒数=second,控制台UID=b,
                    工作区活动=False,调用会话在控制台=False,控制台当前用户=False);decoded.append(row)
            right=record('会话信号',11,False);right['信号']='workspaceActive';decoded.append(right)
            for seq,second in enumerate([1,3,8],12):
                row=record('会话窗口采样',seq,False);row.update(信号='workspaceActive',采样秒数=second);decoded.append(row)
            decoded.append(record('正常退出',15,False));return list(map(wrap,decoded))
        for b in [None,0,501]:
            result=p.assess(scenario(b),plan('切换用户'));self.assertEqual(result['稳定异UID控制台候选'],[])
        result=p.assess(scenario(502),plan('切换用户'))
        self.assertEqual(result['判定'],'证据不足');self.assertEqual(result['真实切换用户'],'待测')
        self.assertEqual(result['工作区离开返回'],'通过');self.assertEqual(result['稳定异UID控制台候选'][0]['稳定异UID'],502)
    def test_complete_native_login_fixture_passes_only_parser(self):
        self.assertEqual(p.assess(fixture(),plan())['真实登录'],'通过')
    def test_ordinary_is_layered_and_never_promoted_to_login(self):
        result=p.assess(fixture(False),plan())
        self.assertEqual(result['判定'],'证据不足');self.assertEqual(result['普通冷启动对照'],'通过')
        self.assertEqual(result['真实登录'],'待测')
        self.assertEqual(p.assess(fixture(False),plan('普通对照'))['判定'],'通过')
    def test_same_subsystem_forged_process_path_and_outer_pid_are_rejected(self):
        for key,value in [('processImagePath','/测试/伪造.app/Contents/MacOS/NTFSWorkbench'),('processID',999)]:
            rows=fixture();rows[0][key]=value
            self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_missing_redacted_unknown_and_mixed_run_are_inconclusive(self):
        self.assertRaises(p.EvidenceIncomplete,p.assess,[],plan())
        rows=fixture();rows[0]['eventMessage']='WF_SESSION <private>'
        self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
        for mutation in [dict(record('启动完成',2),额外='unknown'),dict(record('启动完成',2),验收编号=str(uuid.uuid4()).upper()),
                         dict(record('启动完成',2),UID=502),dict(record('启动完成',2),事件='未知'),dict(record('启动完成',2),PID=True)]:
            rows=fixture();rows[1]=wrap(mutation)
            self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_gaps_missing_tail_and_missing_sampling_are_inconclusive(self):
        for rows in [fixture()[:-1],fixture()[1:],fixture()[:4]+fixture()[5:],fixture()+fixture()[-1:]]:
            self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_disk_requests_or_auto_on_are_failures(self):
        for mutation in [dict(record('启动完成',2),自动管理=True),record('请求挂载',2),record('请求自动挂载',2),record('请求卸载',2),record('请求弹出',2)]:
            rows=fixture();rows[1]=wrap(mutation)
            self.assertRaises(p.SafetyFailure,p.assess,rows,plan())
    def test_background_activation_confirmation_window_and_incomplete_cleanup_fail(self):
        for field,value in [('前台确认',True),('待确认',True),('应用活动',True),('激活策略',0),('最小化内容窗数',1)]:
            row=record('启动窗口采样',4);row.update(采样秒数=1);row[field]=value
            rows=fixture();rows[3]=wrap(row)
            self.assertRaises(p.SafetyFailure,p.assess,rows,plan())
        rows=fixture();tail=record('正常退出',7);tail['会话监控存在']=True;rows[-1]=wrap(tail)
        self.assertRaises(p.SafetyFailure,p.assess,rows,plan())
    def test_launch_context_must_remain_exact_after_finish(self):
        rows=fixture();r=record('启动窗口采样',4);r.update(采样秒数=1,原始启动原因=None);rows[3]=wrap(r)
        self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_duplicate_json_keys_are_not_silently_accepted(self):
        rows=fixture();message=rows[1]['eventMessage'];rows[1]['eventMessage']=message[:-1]+',"PID":1234}'
        self.assertRaises(p.EvidenceIncomplete,p.assess,rows,plan())
    def test_seconds_precision_does_not_reject_same_start_second(self):
        rows=fixture();r=record('即将完成启动',1);r['时间']='2027-01-15T08:00:00Z';rows[0]=wrap(r)
        self.assertEqual(p.assess(rows,plan())['判定'],'通过')

class CommandBoundaries(unittest.TestCase):
    def invoke(self,action,*,pids=None,changed=False,expired=False,new_identity=False,auto_off=True,prior=None,unavailable=False,shadow=False):
        # 只在build中新建模拟文件夹，不触及真实HOME、defaults或任何设备；保留全部证据。
        folder=Path(tempfile.mkdtemp(prefix='模拟-',dir=test_directory()))
        frozen=plan();frozen.update(格式=1,UID=os.geteuid(),原专用键=p.freeze_value(prior))
        frozen['安装身份']['应用路径']='/测试/NTFSWriteFlow.app'
        if expired:frozen['配置']['到期时间']=1800000010
        path=folder/'计划.json';p.save_json(path,frozen)
        current=p.freeze_value({'其他运行':True}) if changed else frozen['原专用键']
        if action=='disarm':current=p.freeze_value(frozen['配置']) if not changed else current
        identity=copy.deepcopy(frozen['安装身份'])
        if new_identity:identity['主程序SHA256']='e'*64
        inspection={'安装身份':identity,'偏好':{'专用键':current,'专用键遮蔽':shadow,'自动管理':'关闭' if auto_off else '开启'},
                    '安全基线通过':auto_off and not shadow,'产品运行PID':pids or []}
        writes=[]
        class FakeCommands:
            def __init__(self,folder):pass
            def __call__(self,args,input_data=None,**kwargs):
                if args==['/测试偏好工具','read']:return json.dumps(inspection['偏好']).encode()
                if args[0]!='/测试偏好工具' or args[1] not in ('arm','restore'):raise AssertionError('禁止模拟测试产生其他命令')
                data=json.loads(input_data);writes.append((args,data))
                return json.dumps({'专用键':data['新值']}).encode()
        argv=['会话验收准备.py',action,'--plan',str(path)] if action else ['会话验收准备.py']
        with patch.object(p.sys,'argv',argv),patch.object(p.Path,'home',return_value=folder),patch.object(p,'Commands',FakeCommands),\
             patch.object(p,'preference_tool',return_value='/测试偏好工具'),patch.object(p,'preflight',return_value=inspection,side_effect=OSError('模拟安装已移除或磁盘查询失败') if unavailable else None),\
             patch.object(p.time,'time',return_value=1800000100),contextlib.redirect_stdout(io.StringIO()):
            code=p.main()
        return code,writes,frozen
    def test_default_preflight_and_plan_never_apply(self):
        for action in ['', 'plan']:
            code,writes,_=self.invoke(action);self.assertEqual(code,0);self.assertEqual(writes,[])
    def test_arm_requires_stopped_product_and_safe_baseline(self):
        for kwargs in [dict(pids=[123]),dict(auto_off=False),dict(expired=True),dict(changed=True)]:
            code,writes,_=self.invoke('arm',**kwargs);self.assertEqual(code,1);self.assertEqual(writes,[])
    def test_changed_installation_never_arms_old_plan(self):
        code,writes,_=self.invoke('arm',new_identity=True);self.assertEqual(code,78);self.assertEqual(writes,[])
    def test_explicit_arm_only_sends_fixed_tool_one_key_payload(self):
        code,writes,frozen=self.invoke('arm');self.assertEqual(code,0);self.assertEqual(len(writes),1)
        args,data=writes[0];self.assertEqual(args,['/测试偏好工具','arm'])
        self.assertEqual(p.thaw_value(data['新值']),frozen['配置']);self.assertEqual(data['旧值'],frozen['原专用键'])
    def test_disarm_preserves_later_changes_and_restores_exact_backup(self):
        code,writes,_=self.invoke('disarm',changed=True);self.assertEqual(code,1);self.assertEqual(writes,[])
        prior={'先前专用值':'保留','布尔':True}
        code,writes,_=self.invoke('disarm',prior=prior);self.assertEqual(code,0)
        self.assertEqual(writes[0][0],['/测试偏好工具','restore']);self.assertEqual(p.thaw_value(writes[0][1]['新值']),prior)
    def test_disarm_does_not_depend_on_updated_installation_or_disk_state(self):
        code,writes,_=self.invoke('disarm',new_identity=True,auto_off=False,unavailable=True)
        self.assertEqual(code,0);self.assertEqual(len(writes),1)
    def test_shadowed_key_is_never_changed_in_any_domain(self):
        for action in ['arm','disarm']:
            code,writes,_=self.invoke(action,shadow=True);self.assertEqual(code,1);self.assertEqual(writes,[])
    def test_clean_checkout_creates_its_own_test_parent(self):
        fresh=Path(tempfile.mkdtemp(prefix='清洁根-',dir=test_directory()))
        with patch.object(p,'ROOT',fresh):code,writes,_=self.invoke('arm')
        self.assertEqual(code,0);self.assertEqual(len(writes),1)

class NativeComparison(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder=Path(tempfile.mkdtemp(prefix='原生比较-',dir=test_directory()))
        cls.binary=cls.folder/'偏好纯比较'
        subprocess.run(['xcrun','swiftc','-swift-version','6','-warnings-as-errors',str(Path(__file__).with_name('会话验收偏好.swift')),'-o',str(cls.binary)],check=True,capture_output=True)
    def test_actual_swift_comparator_distinguishes_nested_boolean_and_number(self):
        for a,b in [(1,True),({'版本':1},{'版本':True}),({'列表':[{'值':0}]},{'列表':[{'值':False}]})]:
            data=json.dumps({'旧值':p.freeze_value(a),'新值':p.freeze_value(b)}).encode()
            result=subprocess.run([str(self.binary),'compare'],input=data,capture_output=True,check=True)
            self.assertFalse(json.loads(result.stdout)['相等'])
    def test_native_effective_preference_report_detects_shadow_and_active_auto(self):
        for precise,effective,auto,shadow,state in [(None,None,False,False,'关闭'),(None,plan()['配置'],True,True,'开启'),
                                                   (plan()['配置'],plan()['配置'],'false',False,'未知')]:
            data=json.dumps({'精确键':p.freeze_value(precise),'有效键':p.freeze_value(effective),'有效自动管理':p.freeze_value(auto)}).encode()
            result=subprocess.run([str(self.binary),'inspect'],input=data,capture_output=True,check=True)
            report=json.loads(result.stdout);self.assertEqual(report['专用键遮蔽'],shadow);self.assertEqual(report['自动管理'],state)
    def test_equal_valued_host_or_managed_shadow_is_still_rejected(self):
        for host,forced in [(True,False),(False,True)]:
            config=p.freeze_value(plan()['配置'])
            data=json.dumps({'精确键':config,'有效键':config,'有效自动管理':p.freeze_value(False),
                             '当前主机键存在':host,'受管键':forced}).encode()
            result=subprocess.run([str(self.binary),'inspect'],input=data,capture_output=True,check=True)
            self.assertTrue(json.loads(result.stdout)['专用键遮蔽'])

if __name__=='__main__':unittest.main()
