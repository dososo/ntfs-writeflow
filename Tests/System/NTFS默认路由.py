#!/usr/bin/env python3
"""只创建本次原始及GPT NTFS镜像，观察默认只读接入；无拦截规则，不接收外部设备参数。"""
from pathlib import Path
import subprocess, plistlib, hashlib, json, tempfile, sys, time, struct, uuid, zlib
ROOT=Path(__file__).resolve().parents[2]
assert len(sys.argv)==1
OUT=Path(tempfile.mkdtemp(prefix='NTFS默认路由-',dir=ROOT/'build/0.2.0'))
def command(args,required=True):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=40)
    result={'参数':list(map(str,args)),'退出码':p.returncode,'输出':p.stdout.decode(errors='replace'),'错误':p.stderr.decode(errors='replace')}
    (OUT/f'命令-{len(list(OUT.glob("命令-*"))):03}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    if required and p.returncode:raise RuntimeError('命令失败：'+str(args[0]))
    return p,result
def data(args):return plistlib.loads(command(args)[0].stdout)
def maps(image):return [x for x in data(['hdiutil','info','-plist'])['images'] if Path(x['image-path']).resolve()==image.resolve()]
def own(image):
    values=maps(image);assert len(values)==1
    whole=values[0]['system-entities'][0]['dev-entry'].removeprefix('/dev/')
    for entity in values[0]['system-entities']:
        info=data(['diskutil','info','-plist',entity['dev-entry']])
        if info.get('WholeDisk'):
            assert info['DeviceIdentifier']==whole and info.get('VirtualOrPhysical')=='Virtual' and info['IOKitSize']==image.stat().st_size
        else:
            assert info.get('ParentWholeDisk')==whole and info.get('BusProtocol')=='Disk Image' and info['IOKitSize']==64*1024*1024
    return values[0]['system-entities']
def cleanup(image):
    if not maps(image):return
    entities=own(image)
    for entity in entities:
        info=data(['diskutil','info','-plist',entity['dev-entry']])
        if info.get('MountPoint'):command(['diskutil','unmount',entity['dev-entry']])
    entities=own(image);command(['hdiutil','detach',entities[0]['dev-entry']]);assert not maps(image)
results=[]
metadata=ROOT/'build/0.2.0/NTFS默认路由编译元数据.json'
if metadata.exists():
    buildinfo=json.loads(metadata.read_text());buildinfo['观察脚本SHA256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (OUT/'受测编译元数据.json').write_text(json.dumps(buildinfo,ensure_ascii=False,indent=2))
for gpt in [False,True]:
    tag='GPT分区' if gpt else '无分区'
    part=OUT/(tag+'-文件系统.img')
    with part.open('wb') as f:f.truncate(64*1024*1024)
    command([ROOT/'build/engine/arm64/ntfsprogs/mkntfs','-F','-Q','-p','2048' if gpt else '0','-L','WF_ROUTE',part])
    image=part
    if gpt:
        image=OUT/'GPT完整磁盘.img';sector=512;count=262144;start=2048;partsize=131072
        table=bytearray(128*128)
        table[:16]=uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7').bytes_le
        table[16:32]=uuid.uuid4().bytes_le
        struct.pack_into('<QQQ',table,32,start,start+partsize-1,0)
        label='WF_NTFS_ROUTE'.encode('utf-16le');table[56:56+len(label)]=label
        diskid=uuid.uuid4().bytes_le
        def header(current,backup,tablelba):
            h=bytearray(512)
            struct.pack_into('<8sIIIIQQQQ16sQIII',h,0,b'EFI PART',0x10000,92,0,0,current,backup,34,count-34,diskid,tablelba,128,128,zlib.crc32(table))
            struct.pack_into('<I',h,16,zlib.crc32(h[:92]));return h
        mbr=bytearray(512);mbr[446:462]=struct.pack('<B3sB3sII',0,b'\0\x02\0',0xee,b'\xff\xff\xff',1,count-1);mbr[510:512]=b'\x55\xaa'
        with image.open('wb') as f:
            f.truncate(count*512);f.seek(0);f.write(mbr);f.write(header(1,count-1,2));f.write(table)
            f.seek(start*sector);f.write(part.read_bytes());f.seek((count-33)*sector);f.write(table);f.write(header(count-1,1,count-33))
    before=hashlib.sha256(image.read_bytes()).hexdigest()
    probe=subprocess.Popen([ROOT/'build/0.2.0/NTFS默认路由'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    item={'介质类型':tag,'范围':'本次自建NTFS只读镜像；没有拦截策略、合成GUID或竞争放行'}
    seedids=[]
    try:
        assert probe.stdout.readline().strip()=='监控就绪'
        attach=data(['hdiutil','attach','-nomount','-readonly','-plist',image]);entities=own(image)
        seedids=[command([ROOT/'build/system-tests/只读介质身份',x['dev-entry'].removeprefix('/dev/')])[0].stdout.decode().strip() for x in entities]
        item['首次映射核验']=[{'设备':x['dev-entry'],'介质ID':i,'容量':data(['diskutil','info','-plist',x['dev-entry']])['IOKitSize']} for x,i in zip(entities,seedids)]
        time.sleep(.5);cleanup(image);time.sleep(.5)
        _, item['默认只读接入']=command(['hdiutil','attach','-readonly','-mount','optional','-nobrowse','-plist',image],required=False)
        time.sleep(1)
        if maps(image):item['第二次保留映射']=own(image)
        output,err=probe.communicate('结束\n',timeout=10);assert probe.returncode==0,err
        trace=json.loads(output)
        seed=[e for e in trace if e['介质ID'] in seedids]
        uuids={e['卷UUID'] for e in seed if e['卷UUID']}
        item['首次自有介质事件']=seed
        item['同一文件系统再次默认接入事件']=[e for e in trace if e['介质ID'] not in seedids and e['卷UUID'] in uuids]
        approvals=[e for e in item['同一文件系统再次默认接入事件'] if e['阶段']=='approval']
        item['默认NTFS实际发起批准']=bool(approvals)
        item['默认批准均有同代缓存']=bool(approvals) and all(e['同代缓存命中'] for e in approvals)
        item['范围内未能用卷UUID归属的后续事件']=[e for e in trace if e['介质ID'] not in seedids and not e['卷UUID'] and e['容量'] in [64*1024*1024,128*1024*1024]]
    except Exception as error:item['测试错误']=str(error)
    finally:
        if probe.poll() is None:
            try:
                output,err=probe.communicate('结束\n',timeout=10);item['故障时事件']=json.loads(output)
            except Exception as error:item['观察器清理错误']=str(error);probe.terminate()
        try:cleanup(image);item['镜像已正常释放']=not maps(image)
        except Exception as error:item['介质清理错误']=str(error)
        item['镜像SHA一致']=hashlib.sha256(image.read_bytes()).hexdigest()==before
        results.append(item)
        (OUT/'结果.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
print(OUT)
for item in results:
    print(json.dumps({k:v for k,v in item.items() if k in ['介质类型','测试错误','镜像已正常释放','镜像SHA一致','默认NTFS实际发起批准','默认批准均有同代缓存']},ensure_ascii=False))
sys.exit(0 if all(not item.get('测试错误') and item.get('镜像已正常释放') and item['镜像SHA一致'] and item.get('默认NTFS实际发起批准') and item.get('默认批准均有同代缓存') for item in results) else 1)
