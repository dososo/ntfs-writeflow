#!/usr/bin/env python3
"""只终止本工具启动的测试子进程；设备集成入口不接受外部路径。"""
import json
import os
import selectors
import time

PHASES = ('before-event', 'record-pending', 'mount-confirmed')

def checkpoint_matches(packet, process_id, token, phase):
    return (isinstance(packet, dict) and packet.get('kind') == 'checkpoint'
            and type(packet.get('pid')) is int and packet['pid'] == process_id
            and packet.get('token') == token and packet.get('phase') == phase
            and phase in PHASES)

def wait_checkpoint(process, token, phase, timeout=15, evidence=None):
    if phase not in PHASES or process.stdout is None:
        raise RuntimeError('检查点阶段或子进程输出不可核实')
    descriptor = process.stdout.fileno()
    os.set_blocking(descriptor, False)
    deadline = time.monotonic() + timeout
    buffer = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(descriptor, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(min(0.1, max(0, deadline-time.monotonic()))):
                if process.poll() is not None:break
                continue
            chunk = os.read(descriptor, 4096)
            if not chunk:break
            if evidence is not None:
                evidence.write(chunk);evidence.flush()
            buffer.extend(chunk)
            if len(buffer) > 65536:raise RuntimeError('检查点输出超限')
            while b'\n' in buffer:
                line, _, remaining = buffer.partition(b'\n');buffer = bytearray(remaining)
                packet = json.loads(line)
                if not checkpoint_matches(packet, process.pid, token, phase):
                    raise RuntimeError('检查点并非本次精确子进程/令牌/阶段')
                return packet
    raise RuntimeError('未在期限内收到本次子进程检查点')

def terminate_owned(process, packet, token, phase):
    if not checkpoint_matches(packet, process.pid, token, phase) or process.poll() is not None:
        raise RuntimeError('拒绝终止非本次活动子进程或不匹配检查点')
    process.kill()  # 只使用本工具创建的Popen对象，不采用报告中的PID执行信号。
    result = process.wait(timeout=5)
    if result != -9:raise RuntimeError('未确认本次子进程由SIGKILL终止')
    return result

# 以下为显式运行的设备集成；导入本模块只提供纯测试函数，不创建镜像。
from pathlib import Path
import hashlib
import importlib.util
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
CAPACITY = 128 * 1024 * 1024
SENTINEL = bytes((i * 17 + 3) % 251 for i in range(65_573))


def verified_mapping(image, capacity, run):
    """只接受本次单介质、精确文件映射，不将BSD名称本身当身份。"""
    values = plistlib.loads(run(['/usr/bin/hdiutil','info','-plist']))['images']
    matches = [entry for entry in values if Path(entry['image-path']).resolve() == Path(image).resolve()]
    if len(matches) != 1 or len(matches[0]['system-entities']) != 1:
        raise RuntimeError('本次镜像映射不是唯一单介质')
    device = matches[0]['system-entities'][0]['dev-entry']
    if not re.fullmatch(r'/dev/disk[0-9]+', device):raise RuntimeError('不是本次完整镜像设备')
    info = plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',device]))
    if info.get('VirtualOrPhysical') != 'Virtual' or info.get('IOKitSize') != capacity:
        raise RuntimeError('不是本次已核验容量的虚拟镜像')
    return device, info


def inspect_checkpoint_state(phase, packet, info):
    mount = info.get('MountPoint')
    if phase in ('before-event','record-pending'):
        if mount:raise RuntimeError('提交前/查询回包挂起阶段出现非预期挂载')
        return '未挂载'
    if phase != 'mount-confirmed' or not mount or mount != packet.get('mount_point') or packet.get('provider') != 'blntfs':
        raise RuntimeError('挂载确认检查点与真实当前挂载不符')
    return '已挂载；由恢复进程再次核验实际提供方与实例'


def main():
    if len(sys.argv) != 1:raise SystemExit('不接受外部设备或镜像参数')
    if os.geteuid() == 0:raise SystemExit('仅以已启用扩展的普通用户运行，禁止sudo')
    if shutil.disk_usage('/private/tmp').free < 20*1024**3 + 3*CAPACITY:
        raise SystemExit('宿主剩余空间不足，拒绝创建镜像')
    worker = ROOT/'build/0.2.0/中断恢复子进程'
    formatter = ROOT/'build/engine/arm64/ntfsprogs/mkntfs'
    identity = ROOT/'build/system-tests/只读介质身份'
    inventory = ROOT/'build/system-tests/扩展清单复核'
    for binary in (worker,formatter,identity,inventory):
        if not binary.is_file() or binary.is_symlink() or not os.access(binary,os.X_OK):
            raise SystemExit('缺少已构建的可信工具：'+str(binary))
    output = Path(tempfile.mkdtemp(prefix='中断恢复-',dir=ROOT/'build/0.2.0'))
    spec = importlib.util.spec_from_file_location('owned_image_cleanup',Path(__file__).with_name('测试镜像清理.py'))
    cleanup = importlib.util.module_from_spec(spec);spec.loader.exec_module(cleanup)
    result = {'范围':'仅本工具新建镜像和精确Popen子进程；注入事件/GUID/规则版本/竞争clear/会话，真实AppModel与DiskService/FSKit；不是实际GUI进程、断电或实体验收',
              '子进程SHA256':hashlib.sha256(worker.read_bytes()).hexdigest(),
              '样本':[],'结果':'进行中'}
    def save():
        (output/'结果.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    command_number = 0
    def run(arguments):
        nonlocal command_number
        fixed={'hdiutil':'/usr/bin/hdiutil','diskutil':'/usr/sbin/diskutil'}
        command = [fixed.get(str(arguments[0]),str(arguments[0])),*map(str,arguments[1:])]
        response = subprocess.run(command,capture_output=True,timeout=40)
        command_number += 1
        (output/f'命令-{command_number:03d}.json').write_text(json.dumps({'命令':command,'退出码':response.returncode,'输出':response.stdout.decode(errors='replace'),'错误':response.stderr.decode(errors='replace')},ensure_ascii=False,indent=2))
        if response.returncode:raise RuntimeError('本次固定命令失败：'+command[0])
        return response.stdout
    def completed_worker(operation, context, sample):
        with (output/(sample['阶段']+'-'+operation+'-错误.txt')).open('wb') as errors:
            process = subprocess.Popen([str(worker),operation,str(context)],stdout=subprocess.PIPE,stderr=errors)
            try:stdout,_ = process.communicate(timeout=120)
            except subprocess.TimeoutExpired:
                process.kill();stdout,_ = process.communicate(timeout=5)
                (output/(sample['阶段']+'-'+operation+'-输出.txt')).write_bytes(stdout)
                raise RuntimeError('本工具'+operation+'子进程超时，已仅终止该明确PID')
        (output/(sample['阶段']+'-'+operation+'-输出.txt')).write_bytes(stdout)
        packets = [json.loads(line) for line in stdout.splitlines() if line]
        if process.returncode != 0 or len(packets) != 1 or packets[0].get('status') != 'passed' or packets[0].get('operation') != operation:
            raise RuntimeError('本工具'+operation+'子进程未通过，保留输出和现场')
        return packets[0]
    save()
    try:
        preflight = json.loads(run([inventory]))
        installed = Path.home()/'Applications/NTFSWriteFlow.app/Contents/Extensions/NTFSFileSystem.appex'
        result['受测扩展SHA256'] = hashlib.sha256((installed/'Contents/MacOS/NTFSFileSystem').read_bytes()).hexdigest()
        if preflight.get('本应用扩展数') != 1 or preflight['扩展'][0].get('启用') is not True or Path(preflight['扩展'][0]['路径']).resolve() != installed.resolve():
            raise RuntimeError('没有唯一且位于标准安装路径的已启用扩展')
        result['扩展登记核验'] = preflight
    except Exception as error:
        result.update(结果='前置中止，未创建镜像',错误=str(error));save()
        print(json.dumps(result,ensure_ascii=False));print('证据：'+str(output));return 1
    save()
    for phase in PHASES:
        folder = Path(tempfile.mkdtemp(prefix='writeflow-interruption-',dir='/private/tmp'))
        image = folder/'本次.img'
        sample = {'阶段':phase,'目录':str(folder),'镜像':str(image),'结果':'进行中'}
        result['样本'].append(sample);save()
        process = None
        context = None
        try:
            fd = os.open(image,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            try:os.ftruncate(fd,CAPACITY)
            finally:os.close(fd)
            run([formatter,'-F','-Q','-L','WF_INTERRUPT',image])
            run(['/usr/bin/hdiutil','attach','-nomount','-nobrowse','-readwrite','-plist',image])
            device, info = verified_mapping(image,CAPACITY,run)
            if info.get('MountPoint'):raise RuntimeError('新镜像已有非预期挂载，保留')
            media = int(run([identity,device.removeprefix('/dev/')]).decode().strip())
            if media <= 0:raise RuntimeError('缺实时介质登记身份')
            token = str(uuid.uuid4()).upper()
            context = folder/'上下文.json'
            with context.open('x') as file:
                json.dump(dict(root=str(folder),image=str(image),device=device,mediaID=media,capacity=CAPACITY,token=token),file)
            os.chmod(context,0o600)
            sample['准备'] = completed_worker('prepare',context,sample)
            if sample['准备']['bytes'] != len(SENTINEL) or sample['准备']['sha256'] != hashlib.sha256(SENTINEL).hexdigest():
                raise RuntimeError('准备基准内容不符')
            baseline = hashlib.sha256(image.read_bytes()).hexdigest()
            with (output/(phase+'-中断子进程错误.txt')).open('wb') as errors, (output/(phase+'-中断子进程原始输出.txt')).open('wb') as evidence:
                process = subprocess.Popen([str(worker),phase,str(context)],stdout=subprocess.PIPE,stderr=errors)
                packet = wait_checkpoint(process,token,phase,timeout=90,evidence=evidence)
                sample.update(检查点=packet,实际终止PID=process.pid,实际SIGKILL退出码=terminate_owned(process,packet,token,phase))
                process.stdout.close()
            current_device, current = verified_mapping(image,CAPACITY,run)
            if current_device != device:raise RuntimeError('中断后设备映射已变化')
            sample['中断后状态'] = inspect_checkpoint_state(phase,packet,current)
            if phase != 'mount-confirmed' and hashlib.sha256(image.read_bytes()).hexdigest() != baseline:
                raise RuntimeError('事件前或查询回包挂起阶段改变整镜像')
            sample['恢复'] = completed_worker('recover',context,sample)
            if sample['恢复']['sha256'] != hashlib.sha256(SENTINEL).hexdigest():raise RuntimeError('恢复基准摘要不符')
            sample['结果'] = '通过'
        except Exception as error:
            sample.update(结果='失败',错误=str(error))
        finally:
            if process is not None and process.poll() is None:
                process.kill();process.wait(timeout=5)
                sample['失败后仅清理本工具子进程PID'] = process.pid
            if context is not None:
                try:sample['已知自有卷正常清理'] = completed_worker('release',context,sample)
                except Exception as error:sample['挂载清理错误'] = str(error)
            try:sample['映射清理'] = cleanup.release_owned_image(image,CAPACITY,run)
            except Exception as error:sample['清理错误'] = str(error)
            save()
        if sample['结果'] != '通过' or '挂载清理错误' in sample or '清理错误' in sample or not sample.get('映射清理',{}).get('镜像已正常释放'):
            result['结果'] = '失败，后续样本未运行';break
    else:result['结果'] = '通过'
    result['边界'] = '真实SIGKILL测试子进程；第三阶段是系统挂载确认后、协调器尚未回包，不证明内核mount进行中。恢复是独立程序调用生产正常卸载/RO复读，不证明实际应用自动崩溃恢复、掉电、热拔插、登录或实体20轮。'
    save();print(json.dumps(result,ensure_ascii=False,indent=2));print('证据：'+str(output))
    return 0 if result['结果']=='通过' else 1

if __name__=='__main__':
    sys.exit(main())
