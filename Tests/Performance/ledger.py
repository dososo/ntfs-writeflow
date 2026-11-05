"""独占、持久化的逻辑写入额度账本；失败/中断预留额度不退还。"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

class LedgerError(RuntimeError): pass

class Ledger:
    def __init__(self,path,plan):
        self.path=Path(path);self.plan=plan;self.fd=None
    def __enter__(self):
        if not self.path.is_absolute() or self.path.parent.resolve()!=self.path.parent:
            raise LedgerError('账本必须为规范绝对路径，父目录不得含符号链接。')
        self.fd=os.open(self.path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            s=os.fstat(self.fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or stat.S_IMODE(s.st_mode)&0o077:
                raise LedgerError('账本不是当前用户私有普通文件。')
            fcntl.flock(self.fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            signature=hashlib.sha256(json.dumps(self.plan,sort_keys=True).encode()).hexdigest()
            raw=os.read(self.fd,8*1024*1024+1)
            if len(raw)>8*1024*1024:raise LedgerError('账本超限。')
            self.data=json.loads(raw) if raw else dict(schema=1,plan_sha256=signature,reserved_write_bytes=0,reserved_by_cache={'buffered':0,'nocache-requested':0},attempts=[])
            if self.data['plan_sha256']!=signature:raise LedgerError('账本计划摘要不一致，拒绝改换额度。')
            known={step['id']:step for step in self.plan['steps']};tokens=set();total=0;by_cache={'buffered':0,'nocache-requested':0}
            for attempt in self.data['attempts']:
                step=known.get(attempt.get('step'))
                if not step or attempt.get('reserved_bytes')!=step['write_budget_bytes'] or not attempt.get('token') or attempt['token'] in tokens:
                    raise LedgerError('账本预留记录无效，拒绝重置或减少预算。')
                tokens.add(attempt['token']);total+=attempt['reserved_bytes'];by_cache[step['cache']]+=attempt['reserved_bytes']
            if total!=self.data['reserved_write_bytes'] or total>self.plan['limit_bytes']:
                raise LedgerError('账本累计额度与逐条记录不一致。')
            if by_cache!=self.data['reserved_by_cache'] or max(by_cache.values())>self.plan['cache_limit_bytes']:
                raise LedgerError('账本缓存口径累计额度不一致或超限。')
            self.save();return self
        except Exception:
            os.close(self.fd);self.fd=None;raise
    def save(self):
        # IO前先fsync。中途写坏/断电留下坏JSON时下次拒绝，不可静默重置预算。
        raw=(json.dumps(self.data,ensure_ascii=False,indent=2)+'\n').encode()
        os.lseek(self.fd,0,os.SEEK_SET)
        view=memoryview(raw)
        while view:
            n=os.write(self.fd,view);view=view[n:]
        os.ftruncate(self.fd,len(raw));os.fsync(self.fd)
    def reserve(self,step):
        completed={a['step'] for a in self.data['attempts'] if a.get('result',{}).get('status')=='passed'}
        next_step=next((s for s in self.plan['steps'] if s['id'] not in completed),None)
        if next_step is None or next_step!=step:raise LedgerError('必须按固定计划顺序逐步运行；失败须在原步骤重试。')
        total=self.data['reserved_write_bytes']+step['write_budget_bytes']
        if total>self.plan['limit_bytes']:raise LedgerError('累计逻辑写入预算不足；失败及中断额度保留。')
        cache=step['cache'];cache_total=self.data['reserved_by_cache'][cache]+step['write_budget_bytes']
        if cache_total>self.plan['cache_limit_bytes']:raise LedgerError('该缓存口径累计逻辑写入超过独立额度。')
        token=str(uuid.uuid4());self.data['attempts'].append(dict(token=token,step=step['id'],reserved_bytes=step['write_budget_bytes']))
        self.data['reserved_write_bytes']=total;self.data['reserved_by_cache'][cache]=cache_total;self.save();return token
    def result(self,step_id):
        return next((a['result'] for a in reversed(self.data['attempts']) if a['step']==step_id and a.get('result',{}).get('status')=='passed'),None)
    def finish(self,token,result):
        attempt=next(a for a in self.data['attempts'] if a['token']==token)
        # 完整fio JSON和万文件摘要留在单步报告，账本仅保留依赖所需字段。
        keep=['status','run_id','plan_step','provider','media_id','capacity','size_bytes','cache','concurrency',
              'seed','workload','session_name','owner_token','sha256','logical_write_bytes']
        compact={key:result[key] for key in keep if key in result}
        if result.get('workload')!='small-files-and-sync' and 'file_hashes' in result:
            compact['file_hashes']=result['file_hashes']
        if result.get('reason'):compact['reason']=result['reason'][:4096]
        attempt['result']=compact;self.save()
    def __exit__(self,*unused):
        if self.fd is not None:os.close(self.fd)
