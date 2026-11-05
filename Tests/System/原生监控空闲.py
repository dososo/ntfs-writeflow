#!/usr/bin/env python3
"""只运行原生监控，五秒内不接入或操作任何测试盘；不是整机或完整应用能耗验收。"""
from pathlib import Path
import json, subprocess, sys, time
ROOT=Path(__file__).resolve().parents[2]
assert len(sys.argv)==1
probe=subprocess.Popen([ROOT/'build/0.2.0/原生事件顺序'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
def cpu_seconds():
    raw=subprocess.check_output(['ps','-p',str(probe.pid),'-o','time='],text=True).strip()
    parts=raw.split(':')
    return sum(float(x)*60**i for i,x in enumerate(reversed(parts)))
try:
    assert probe.stdout.readline().strip()=='监控就绪'
    before=cpu_seconds(); start=time.monotonic()
    time.sleep(5)
    elapsed=time.monotonic()-start; consumed=cpu_seconds()-before
    output,errors=probe.communicate('结束\n',timeout=10)
    assert probe.returncode==0,errors
    result={'范围':'仅生产原生监控空闲五秒，无盘操作；不是完整应用性能验收','采样秒数':round(elapsed,3),'进程CPU增加秒数':round(consumed,3),'平均单核CPU百分比':round(consumed/elapsed*100,3),'门槛':'五秒CPU增加不超过0.1秒','结果':'通过' if consumed<=0.1 else '失败'}
    (ROOT/'build/0.2.0/原生监控空闲.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps(result,ensure_ascii=False))
finally:
    if probe.poll() is None:
        try:probe.communicate('结束\n',timeout=10)
        except subprocess.TimeoutExpired:probe.terminate()
sys.exit(0 if result['结果']=='通过' else 1)
