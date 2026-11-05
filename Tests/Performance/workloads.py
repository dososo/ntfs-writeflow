"""固定fio作业及小文件操作。所有打开均绑定已核验目录句柄，不删除文件。"""
import hashlib
import json
import os
import stat
import subprocess
import sys
import re
import signal
import tempfile
from pathlib import Path
import time
MIB=1024**2
SEED=20261029

def run_measured(command,timeout,**options):
    descriptor,path=tempfile.mkstemp(prefix='writeflow-time-',suffix='.txt');os.close(descriptor)
    environment=os.environ.copy();environment['LC_ALL']='C'
    input_data=options.pop('input',None)
    if input_data is not None:options['stdin']=subprocess.PIPE
    if options.pop('capture_output',False):options.update(stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    process=subprocess.Popen(['/usr/bin/time','-l','-o',path,*command],start_new_session=True,env=environment,**options)
    try:
        output,errors=process.communicate(input_data,timeout=timeout)
    except subprocess.TimeoutExpired:
        # 新session仅包含本工具创建的测量进程及其子进程，不影响其他驱动/系统进程。
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        process.communicate(timeout=5)
        raise
    raw=Path(path).read_text()
    cpu=re.search(r'([0-9.]+)\s+real\s+([0-9.]+)\s+user\s+([0-9.]+)\s+sys',raw)
    memory=re.search(r'(\d+)\s+maximum resident set size',raw)
    if not cpu or not memory:raise RuntimeError('官方time资源输出格式无法识别，保留：'+path)
    resources=dict(source='/usr/bin/time -l',real_seconds=float(cpu[1]),user_cpu_seconds=float(cpu[2]),
        system_cpu_seconds=float(cpu[3]),maximum_resident_set_bytes=int(memory[1]),raw=raw,raw_path=path,
        scope='该命令官方wait4资源统计；峰值RSS不代表系统总内存或多作业同时RSS之和')
    return subprocess.CompletedProcess(command,process.returncode,output,errors),resources

def hashes(directory,names):
    result={}
    for name in names:
        fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=directory)
        try:
            s=os.fstat(fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_nlink!=1:
                raise RuntimeError('工作集文件所有权、类型或链接数不符。')
            h=hashlib.sha256()
            while block:=os.read(fd,MIB):h.update(block)
            result[name]=dict(sha256=h.hexdigest(),size=s.st_size,inode=s.st_ino)
        finally:os.close(fd)
    return result

def fio_workload(fio,directory,workload,size,concurrency,direct,timeout,initialize):
    names=[f'workload.{n}.dat' for n in range(concurrency)]
    if size%concurrency or size//concurrency%4096:raise RuntimeError('工作集大小须为并发数和4KiB的整数倍。')
    length=size//concurrency
    if initialize:
        for name in names:
            fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
            try:os.ftruncate(fd,length)
            finally:os.close(fd)
    else:
        original=hashes(directory,names)
        if any(v['size']!=length for v in original.values()):raise RuntimeError('依赖工作集大小不符。')
    random=workload.startswith('random')
    rw={'sequential-read':'read','random-write':'randwrite','random-read':'randread'}.get(workload,'write')
    # 随机写使用不重复随机映射，每文件覆盖一次；随机读用相同验证头逐块验证。
    content=['[global]','ioengine=psync','iodepth=1','numjobs=1',f'rw={rw}',f'bs={4096 if random else MIB}',
        f'size={length}','allow_file_create=0',f'direct={int(direct)}',f'randseed={SEED}',
        'randrepeat=1','norandommap=0','verify=sha256','do_verify=1','verify_fatal=1','end_fsync=1','unlink=0']
    for n,name in enumerate(names):content.extend([f'[writeflow-{n}]',f'filename={name}'])
    command=[str(fio),'--output-format=json','-']
    started=time.monotonic()
    process,resources=run_measured(command,input=('\n'.join(content)+'\n').encode(),preexec_fn=lambda:os.fchdir(directory),
        pass_fds=(directory,),capture_output=True,timeout=timeout)
    elapsed=time.monotonic()-started
    if len(process.stdout)>8*MIB:raise RuntimeError('fio输出超限。')
    raw=json.loads(process.stdout)
    if process.returncode or len(raw.get('jobs',[]))!=concurrency or any(j.get('error') for j in raw['jobs']):
        raise RuntimeError('fio运行或内容验证失败：'+process.stderr.decode(errors='replace')+' '+json.dumps(raw))
    writes=sum(j['write']['io_bytes'] for j in raw['jobs']);reads=sum(j['read']['io_bytes'] for j in raw['jobs'])
    expected_write=0 if rw in ['read','randread'] else size
    if writes!=expected_write or (not expected_write and reads!=size):raise RuntimeError('fio实际IO字节数与固定计划不一致。')
    return dict(duration_seconds=elapsed,command=command,fio_jobfile='\n'.join(content),fio_json=raw,
        fio_stderr=process.stderr.decode(errors='replace'),logical_write_bytes=writes,
        fio_bytes_per_second=sum(j['write' if expected_write else 'read']['bw_bytes'] for j in raw['jobs']),
        file_hashes=hashes(directory,names),fio_version=raw.get('fio version'),ioengine='psync',iodepth=1,numjobs=1,
        resources=resources,fio_cpu_jobs=[dict(jobname=j['jobname'],user_cpu_percent=j.get('usr_cpu'),system_cpu_percent=j.get('sys_cpu')) for j in raw['jobs']],
        sync_seconds=None,sync_policy='每作业end_fsync=1；fio JSON保留同步统计')

def _small_files(directory,count,direct):
    if not 1<=count<=10000:raise RuntimeError('小文件数量超限。')
    data=hashlib.sha256(str(SEED).encode()).digest()*128
    started=time.monotonic();sync=0;names=[]
    for n in range(count):
        name=f'small-{n:05d}.dat';fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
        try:
            if direct:
                import fcntl
                fcntl.fcntl(fd,48,1) # macOS公开F_NOCACHE；仅表示请求避开缓存。
            if os.write(fd,data)!=len(data):raise RuntimeError('小文件短写。')
            at=time.monotonic();os.fsync(fd);sync+=time.monotonic()-at
            os.lseek(fd,0,os.SEEK_SET)
            if os.read(fd,len(data)+1)!=data:raise RuntimeError('小文件内容验证失败。')
        finally:os.close(fd)
        renamed=f'checked-{n:05d}.dat';os.rename(name,renamed,src_dir_fd=directory,dst_dir_fd=directory);names.append(renamed)
    enumerated=set(os.listdir(directory))-{'.writeflow-owner.json'}
    if enumerated!=set(names):raise RuntimeError('小文件枚举不一致。')
    manifest=hashes(directory,names)
    expected=hashlib.sha256(data).hexdigest()
    if any(v['sha256']!=expected or v['size']!=4096 for v in manifest.values()):raise RuntimeError('小文件完整摘要不一致。')
    elapsed=time.monotonic()-started
    return dict(duration_seconds=elapsed,logical_write_bytes=count*4096,fio_bytes_per_second=count*4096/elapsed,
        file_hashes=manifest,fio_version='不适用-原生POSIX',ioengine='posix',iodepth=1,numjobs=1,
        sync_seconds=sync,sync_policy='每文件fsync；创建→读回→改名→枚举→完整SHA256',small_file_count=count)


def small_files(directory,count,direct,timeout):
    # 自有子进程限定整个小文件步骤耗时；超时保留已生成文件，不自动重试。
    process,resources=run_measured([sys.executable,str(Path(__file__).resolve()),str(directory),str(count),str(int(direct))],
        pass_fds=(directory,),capture_output=True,timeout=timeout)
    if process.returncode:raise RuntimeError('小文件步骤失败：'+process.stderr.decode(errors='replace'))
    if len(process.stdout)>8*MIB:raise RuntimeError('小文件报告超限。')
    result=json.loads(process.stdout);result['resources']=resources;return result

if __name__=='__main__':
    print(json.dumps(_small_files(int(sys.argv[1]),int(sys.argv[2]),bool(int(sys.argv[3]))),ensure_ascii=False))
