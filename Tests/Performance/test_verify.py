"""只读内容复核：允许RO，拒绝报告路径注入，成功/拒绝都不调用卷内写API。"""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid
import benchmark as b

class VerifyTests(unittest.TestCase):
    def fixture(self):
        host=Path(tempfile.mkdtemp(prefix='writeflow-content-verify-')).resolve()
        target=host/'volume';target.mkdir(mode=0o700)
        session_name='WriteFlow-Benchmark-'+str(uuid.uuid4());session=target/session_name;session.mkdir(mode=0o700)
        token=str(uuid.uuid4());(session/'.writeflow-owner.json').write_text(json.dumps(dict(schema=1,token=token)))
        payload=b'writeflow-owned-content\n'
        file=session/'workload.0.dat';file.write_bytes(payload)
        original=dict(schema=2,status='passed',run_id=str(uuid.uuid4()),provider='blntfs',media_id=101,capacity=1024**3,
            session_name=session_name,owner_token=token,workload='sequential-write',size_bytes=len(payload),concurrency=1,
            small_file_count=0,file_hashes={'workload.0.dat':dict(size=len(payload),sha256=hashlib.sha256(payload).hexdigest())})
        source=host/'source.json';source.write_text(json.dumps(original))
        args=SimpleNamespace(source_report=str(source),target=str(target),probe='fixture',expect_provider='ufsd_NTFS',
            expect_media_id=101,expect_capacity=1024**3,output=str(host/'verify.json'))
        state=dict(provider='ufsd_NTFS',media_id=101,capacity=1024**3,internal=False,virtual=False,read_only=True,
                   source='/dev/disk99',mount_identity='fixture-mount',mount_point=str(target),mount_owner_uid=os.getuid())
        def probe(binary,path):
            path=Path(path);st=path.stat()
            actual=state if path==target or target in path.parents else dict(provider='apfs',internal=True,read_only=False)
            return actual|dict(directory_empty_acl=True,directory_device=st.st_dev,directory_inode=st.st_ino)
        return host,target,session,source,original,args,state,probe
    def run_without_volume_writes(self,args,probe):
        real_open=os.open;host=Path(args.output).parent.stat()
        def checked_open(path,flags,*positional,**keywords):
            if flags&os.O_ACCMODE!=os.O_RDONLY:
                self.assertEqual(path,Path(args.output).name)
                parent=os.fstat(keywords['dir_fd']);self.assertEqual((parent.st_dev,parent.st_ino),(host.st_dev,host.st_ino))
                self.assertEqual(flags,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW)
            return real_open(path,flags,*positional,**keywords)
        with patch.object(b,'probe',side_effect=probe),patch.object(b.os,'open',side_effect=checked_open) as opened, \
             patch.object(b.os,'write',side_effect=AssertionError('不得写卷')), \
             patch.object(b.os,'mkdir',side_effect=AssertionError('不得建卷目录')), \
             patch.object(b.os,'rename',side_effect=AssertionError('不得改名')), \
             patch.object(b.os,'unlink',side_effect=AssertionError('不得删除')), \
             patch.object(b.os,'ftruncate',side_effect=AssertionError('不得截断')):
            result=b.verify_content(args)
            for call in opened.call_args_list:
                if call.args[1]&os.O_ACCMODE!=os.O_RDONLY:continue # 仅上面已证明的宿主报告FD可写。
                self.assertEqual(call.args[1]&os.O_ACCMODE,os.O_RDONLY)
                self.assertFalse(call.args[1]&(os.O_CREAT|os.O_TRUNC|os.O_APPEND))
            return result
    def test_ro_cross_provider_reads_own_complete_set_with_zero_volume_writes(self):
        host,target,session,source,original,args,state,probe=self.fixture()
        before={p.name:p.read_bytes() for p in session.iterdir()}
        result=self.run_without_volume_writes(args,probe)
        self.assertEqual(result['status'],'passed',result.get('reason'))
        self.assertEqual(result['verification_scope'],'cross-provider')
        self.assertTrue(result['read_only_mount']);self.assertEqual(result['verified_bytes'],original['size_bytes'])
        self.assertEqual(before,{p.name:p.read_bytes() for p in session.iterdir()})
        self.assertEqual(b.summarize([result])['content_verifications'],[result])
    def test_same_provider_is_not_a_performance_sample(self):
        *_,args,state,probe=self.fixture();state['provider']='blntfs';args.expect_provider='blntfs'
        result=self.run_without_volume_writes(args,probe)
        self.assertEqual(result['verification_scope'],'same-provider')
        self.assertFalse(b.summarize([result])['complete']);self.assertEqual(b.summarize([result])['groups'],[])
    def test_wrong_provider_and_changed_instance_refused_without_writes(self):
        for change in ['provider','instance']:
            host,target,session,source,original,args,state,probe=self.fixture()
            count=0
            def changed(binary,path):
                nonlocal count
                result=probe(binary,path)
                if Path(path)==session:
                    count+=1
                    if change=='instance' and count>=2:result['mount_identity']='changed'
                if change=='provider' and Path(path)!=host:result['provider']='ntfs'
                return result
            result=self.run_without_volume_writes(args,changed)
            self.assertNotEqual(result['status'],'passed')
    def test_tampered_missing_symlink_and_hardlink_files_remain_failures(self):
        for defect in ['content','missing','symlink','hardlink']:
            host,target,session,source,original,args,state,probe=self.fixture();file=session/'workload.0.dat'
            if defect=='content':file.write_bytes(b'X'*original['size_bytes'])
            if defect=='missing':file.unlink()
            if defect=='symlink':file.unlink();file.symlink_to(source)
            if defect=='hardlink':os.link(file,host/'other-link')
            result=self.run_without_volume_writes(args,probe)
            self.assertEqual(result['status'],'failed');self.assertEqual(result['files'][0]['status'],'failed')
    def test_all_file_failures_remain_visible_and_other_files_continue(self):
        host,target,session,source,original,args,state,probe=self.fixture()
        payload=(session/'workload.0.dat').read_bytes()
        original['concurrency']=4;original['size_bytes']=4*len(payload)
        for n in range(1,4):(session/f'workload.{n}.dat').write_bytes(payload)
        original['file_hashes']={f'workload.{n}.dat':dict(size=len(payload),sha256=hashlib.sha256(payload).hexdigest()) for n in range(4)}
        source.write_text(json.dumps(original));(session/'workload.0.dat').write_bytes(b'X'*len(payload));(session/'workload.2.dat').unlink()
        result=self.run_without_volume_writes(args,probe)
        self.assertEqual(result['status'],'failed');self.assertEqual(len(result['files']),4)
        self.assertEqual([f['status'] for f in result['files']],['failed','passed','failed','passed'])
    def test_token_and_report_path_injection_refused(self):
        changes=[{'owner_token':str(uuid.uuid4())},{'session_name':'../outside'},
                 {'file_hashes':{'../source.json':dict(size=1,sha256='0'*64)}},
                 {'file_hashes':{'/etc/passwd':dict(size=1,sha256='0'*64)}}]
        for change in changes:
            host,target,session,source,original,args,state,probe=self.fixture();source.write_text(json.dumps(original|change))
            self.assertEqual(self.run_without_volume_writes(args,probe)['status'],'failed')
    def test_rw_mount_requires_manual_read_only_remount(self):
        host,target,session,source,original,args,state,probe=self.fixture();state['read_only']=False
        result=self.run_without_volume_writes(args,probe)
        self.assertEqual(result['status'],'failed');self.assertIn('只读重挂',result['reason'])
    def test_fifo_source_or_marker_is_rejected_without_blocking(self):
        root=Path(tempfile.mkdtemp(prefix='writeflow-json-fifo-')).resolve();fifo=root/'fifo';os.mkfifo(fifo,0o600)
        code="import sys;sys.path.insert(0,sys.argv[1]);import benchmark as b;\ntry:b.read_owned_json(sys.argv[2])\nexcept b.Refusal:sys.exit(0)\nsys.exit(1)"
        completed=subprocess.run([sys.executable,'-c',code,str(Path(__file__).parent),str(fifo)],capture_output=True,timeout=1)
        self.assertEqual(completed.returncode,0,completed.stderr.decode())
    def test_report_destination_on_test_volume_refused_before_write(self):
        host,target,session,source,original,args,state,probe=self.fixture();args.output=str(target/'must-not-exist.json')
        with patch.object(b,'probe',side_effect=probe),self.assertRaises(b.Refusal):b.verify_content(args)
        self.assertFalse(Path(args.output).exists())
