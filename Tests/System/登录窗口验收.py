#!/usr/bin/env python3
"""原字节生产App及委托配无磁盘依赖，验证LaunchServices窗口生命周期。"""
def verify_event(event, pid, token):
    return (isinstance(event,dict) and type(event.get('pid')) is int
            and event['pid']==pid and event.get('token')==token)

def verify_start_order(events):
    kinds=[e.get('event') for e in events]
    return (kinds.count('early-session-monitor')==1 and kinds.count('start-monitoring')==1
            and kinds.index('early-session-monitor')<kinds.index('start-monitoring'))

def visible_roles(event):
    return {w['role'] for w in event['windows'] if w.get('role') in {'main','diagnostics','settings'}
            and w.get('visible') is True and w.get('miniaturized') is False and w.get('titled') is True}

def matches_visible(event, expected):
    count=sum(w.get('visible') is True and w.get('miniaturized') is False and w.get('titled') is True
              for w in event['windows'])
    return visible_roles(event)==expected and count==len(expected)

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]

def main():
    if len(sys.argv)!=1:raise SystemExit('不接受外部应用或进程参数')
    run=Path(tempfile.mkdtemp(prefix='窗口生命周期-',dir=ROOT/'build/0.2.0'))
    source=ROOT/'Sources/App/NTFSWorkbenchApp.swift';stub=Path(__file__).with_name('登录窗口替身.swift')
    frozen=run/'冻结';frozen.mkdir()
    production=source.read_bytes();replacement=stub.read_bytes()
    (frozen/source.name).write_bytes(production);(frozen/stub.name).write_bytes(replacement)
    app=run/'WindowLifecycleProbe.app';binary=app/'Contents/MacOS/WindowLifecycleProbe';binary.parent.mkdir(parents=True)
    bundle_id='com.blteam.writeflow.windowprobe.'+uuid.uuid4().hex
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':binary.name,
        'CFBundleIdentifier':bundle_id,'CFBundleName':'窗口生命周期独立验收','CFBundlePackageType':'APPL',
        'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','NSPrincipalClass':'NSApplication',
        'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'26.0'}))
    result={'范围':'原字节生产App及WorkbenchDelegate+无磁盘替身，经真实LaunchServices启动；登录原因注入，不注册登录项或执行真实登录',
        '生产AppSHA256':hashlib.sha256(production).hexdigest(),'替身SHA256':hashlib.sha256(replacement).hexdigest(),
        '目录':str(run),'独立BundleID':bundle_id,'命令':[],'场景':[],'结果':'进行中'}
    def save():
        (run/'结果.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    def command(args):
        index=len(result['命令'])+1
        process=subprocess.run(list(map(str,args)),capture_output=True,timeout=40)
        (run/f'命令-{index:02d}.log').write_bytes(process.stdout+process.stderr)
        result['命令'].append({'参数':list(map(str,args)),'退出码':process.returncode});save()
        if process.returncode:raise RuntimeError('本轮命令失败，保留日志：'+str(args[0]))
    class Session:
        def __init__(self,name,login,menu):
            self.name=name;self.login=login;self.menu=menu;self.token=str(uuid.uuid4()).upper();self.pid=None
            self.expected_confirmations=0 if login else 1
            self.root=run/name;self.root.mkdir(mode=0o700)
            # GUI测试进程只在私有临时目录收发；避免Documents触发TCC授权干扰时序。
            self.ipc=Path(tempfile.mkdtemp(prefix='writeflow-window-ipc-'));self.ipc.chmod(0o700)
            self.report={'私有通信目录':str(self.ipc),'场景':name,'登录原因注入':login,'菜单偏好':menu,'步骤':[],'结果':'进行中'}
            result['场景'].append(self.report);save()
        def events(self):
            path=self.ipc/'回执.jsonl'
            if not path.exists():return []
            data=path.read_bytes();(self.root/'回执.jsonl').write_bytes(data)
            rows=[json.loads(line) for line in data.split(b'\n')[:-1]]
            if rows and self.pid is None:
                first=rows[0]
                if (first.get('event')!='configured' or first.get('bundle_path')!=str(app)
                        or first.get('bundle_id')!=bundle_id or type(first.get('pid')) is not int or first['pid']<=1):
                    raise RuntimeError('不是本次独立bundle的启动回执')
                self.pid=first['pid'];self.report['实际PID']=self.pid;save()
            if any(not verify_event(e,self.pid,self.token) for e in rows):raise RuntimeError('回执PID/令牌不符')
            return rows
        def wait(self,predicate,description,timeout=8):
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                rows=self.events();found=predicate(rows)
                if found:return found
                time.sleep(0.05)
            raise RuntimeError(self.name+'：超时未观察到'+description)
        def launch(self):
            args=['/usr/bin/open','-n','-g','--stdout',self.root/'标准输出.txt','--stderr',self.root/'标准错误.txt']
            for key,value in {'ROOT':str(self.ipc),'TOKEN':self.token,'LOGIN':str(self.login).lower(),'MENU':str(self.menu).lower()}.items():
                args+=['--env','WRITEFLOW_WINDOW_PROBE_'+key+'='+value]
            command(args+[app])
            rows=self.wait(lambda rows:rows if any(e.get('event')=='start-monitoring' for e in rows) else None,'委托启动')
            if not verify_start_order(rows):raise RuntimeError('早期会话订阅必须在监控启动之前且各一次')
            start=next(e for e in rows if e['event']=='start-monitoring')
            if start['login_reason_injected']!=self.login:raise RuntimeError('委托传入启动原因不符')
            if self.login:
                transitions=[e for e in rows if e.get('event') in {'window-transition','window-notification'}]
                if any(not matches_visible(e,set()) for e in transitions):raise RuntimeError('后台启动早期观察到非预期内容窗口')
            self.report['早期订阅先于监控启动']=True;save();time.sleep(0.8)
        def action(self,action):
            request={'id':str(uuid.uuid4()),'token':self.token,'action':action}
            temporary=self.ipc/'指令.tmp';temporary.write_text(json.dumps(request));os.replace(temporary,self.ipc/'指令.json')
            if action=='quit':return
            return self.wait(lambda rows:next((e for e in rows if e.get('command_id')==request['id']),None),action+'回执')
        def snapshot(self,name,expected,policy=0,minimized=False):
            time.sleep(0.25);event=self.action('sample')
            step={'检查':name,'期望可见角色':sorted(expected),'样本':event}
            self.report['步骤'].append(step);save()
            if not matches_visible(event,expected) or event['activation_policy']!=policy or event['menu_preference']!=self.menu:
                raise RuntimeError(name+'：实际内容窗/激活策略/菜单偏好不符')
            confirmations=sum(e.get('event')=='request-foreground-confirmation' for e in self.events())
            step['前台确认请求次数']=confirmations
            if confirmations!=self.expected_confirmations:raise RuntimeError(name+'：委托前台确认请求次数不符')
            if name=='初始窗口' and self.login:
                observed=[e for e in self.events() if e.get('event') in {'window-transition','window-notification'}]
                if not observed or any(not matches_visible(e,set()) for e in observed):raise RuntimeError('后台启动期间观察到非预期内容窗口')
                step['后台启动零窗观察数']=len(observed)
            save()
            if minimized and not any(w.get('role')=='main' and w['miniaturized'] for w in event['windows']):
                raise RuntimeError(name+'：主窗口没有真实最小化')
        def reopen(self):
            command(['/usr/bin/open','-g',app]);self.expected_confirmations+=1;time.sleep(0.35)
        def quit(self):
            self.action('quit')
            self.wait(lambda rows:next((e for e in rows if e.get('event')=='stop-monitoring'),None),'正常退出stop')
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                try:os.kill(self.pid,0)
                except ProcessLookupError:
                    self.report['正常退出且stop记录']=True;save();return
                time.sleep(0.05)
            raise RuntimeError('本轮应用未正常退出；不杀系统或其他用户进程')
    active=None
    save()
    try:
        command(['xcrun','swiftc','-target','arm64-apple-macos26.0','-swift-version','6','-warnings-as-errors',
                 frozen/source.name,frozen/stub.name,'-o',binary])
        command(['/usr/bin/codesign','--force','--sign','-',app])
        command(['/usr/bin/codesign','--verify','--strict',app])
        result['测试可执行SHA256']=hashlib.sha256(binary.read_bytes()).hexdigest();save()
        for name,login,menu in [('普通启动及窗口边界',False,True),('已有辅助窗退出后后台启动',True,True),
                               ('菜单关闭的后台启动',True,False),('菜单关闭的普通启动',False,False)]:
            active=Session(name,login,menu);active.launch()
            active.snapshot('初始窗口',set() if login else {'main'},policy=1 if login else 0)
            if login:
                active.reopen();active.snapshot('LaunchServices重新打开',{'main'})
            if name=='普通启动及窗口边界':
                active.action('diagnostics');active.action('settings')
                active.snapshot('真实辅助窗口已打开',{'main','diagnostics','settings'})
                active.action('close-auxiliary');active.action('minimize-main')
                active.snapshot('主窗真实最小化',set(),minimized=True)
                active.reopen();active.snapshot('最小化后重新打开',{'main'})
                active.action('diagnostics');active.action('close-main')
                active.snapshot('只剩诊断可见',{'diagnostics'})
                active.reopen();active.snapshot('只剩诊断时重新打开',{'main','diagnostics'})
            active.action('close-all');active.snapshot('关闭最后窗口仍保活',set())
            active.reopen();active.snapshot('零窗口后重新打开',{'main'})
            if name=='普通启动及窗口边界':
                active.action('diagnostics');active.action('settings')
                active.snapshot('带辅助窗口正常退出前',{'main','diagnostics','settings'})
            active.quit();active.report['结果']='通过';active=None;save()
        result['结束时生产源码字节一致']=source.read_bytes()==production
        if not result['结束时生产源码字节一致']:raise RuntimeError('生产App源在运行期间发生变化')
        result['结果']='通过'
    except Exception as error:
        result['结果']='未通过';result['错误']=str(error)
        if active:
            active.report.update(结果='未通过',错误=str(error))
            try:active.quit()
            except Exception as cleanup:result['独立测试应用退出错误']=str(cleanup)
    result['边界']='登录原因和无磁盘模型为注入；未验生产ContentView、真实SMAppService登录事件/登记、真实AppModel启动磁盘工作。菜单关闭验证使用持久偏好并观察窗口行为，不以偏好值声称系统菜单图标视觉验收。'
    save();print(json.dumps({'结果':result['结果'],'错误':result.get('错误'),'证据':str(run),'生产AppSHA256':result['生产AppSHA256']},ensure_ascii=False))
    return 0 if result['结果']=='通过' else 1

if __name__=='__main__':sys.exit(main())
