"""计划/预算与真实小负载流程；生成的独占测试目录全部保留。"""
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent))
import benchmark as b

def fixture_probe(state,path):
    st=Path(path).stat()
    return dict(mount_owner_uid=os.getuid())|state|dict(directory_empty_acl=True,directory_device=st.st_dev,directory_inode=st.st_ino)

class Workflows(unittest.TestCase):
    def test_every_plan_step_has_an_executor_and_dependencies(self):
        p=b.make_plan()
        self.assertTrue(all(s['executable'] for s in p['steps']))
        for s in p['steps']:
            if s['workload'] in ['sequential-read','random-write','random-read']:
                dep=next(x for x in p['steps'] if x['id']==s['depends_on'])
                self.assertEqual((dep['provider'],dep['cache'],dep['sample'],dep['concurrency']),
                                 (s['provider'],s['cache'],s['sample'],s['concurrency']))
    def test_ledger_reserves_failures_and_rejects_out_of_order(self):
        from ledger import Ledger, LedgerError
        path=Path(tempfile.mkdtemp(prefix='writeflow-ledger-')).resolve()/'ledger.json'
        plan=b.make_plan()
        with Ledger(path,plan) as ledger:
            with self.assertRaises(LedgerError):ledger.reserve(plan['steps'][1])
            token=ledger.reserve(plan['steps'][0]);ledger.finish(token,{'status':'failed'})
        with Ledger(path,plan) as ledger:
            self.assertEqual(ledger.data['reserved_write_bytes'],plan['steps'][0]['write_budget_bytes'])
            token=ledger.reserve(plan['steps'][0]);ledger.finish(token,{'status':'passed'})
            self.assertEqual(ledger.data['reserved_write_bytes'],2*plan['steps'][0]['write_budget_bytes'])
    def test_ledger_refuses_over_budget_before_io(self):
        from ledger import Ledger, LedgerError
        plan=b.make_plan();plan['limit_bytes']=1
        path=Path(tempfile.mkdtemp(prefix='writeflow-budget-')).resolve()/'ledger.json'
        with Ledger(path,plan) as ledger:
            with self.assertRaises(LedgerError):ledger.reserve(plan['steps'][0])
            self.assertEqual(ledger.data['attempts'],[])
    def test_report_separates_random_concurrency(self):
        records=[dict(status='passed',run_id=str(n),provider='blntfs',cache='buffered',workload='random-read',
                      concurrency=n,size_bytes=4096,fio_bytes_per_second=10) for n in [1,4]]
        self.assertEqual(len(b.summarize(records)['groups']),2)
    def test_report_rejects_repeated_step_and_plan_parameter_mismatch(self):
        step=next(x for x in b.make_plan()['steps'] if x['workload']=='random-read')
        good=dict(status='passed',run_id='x',plan_step=step['id'],provider=step['provider'],cache=step['cache'],
                  workload=step['workload'],size_bytes=step['size_bytes'],concurrency=step['concurrency'],seed=step['seed'],logical_write_bytes=0,fio_bytes_per_second=10,fio_commit=b.PIN,ioengine='psync',iodepth=1,numjobs=1,small_file_count=0)
        report=b.summarize([good,good|{'run_id':'y'}])
        self.assertTrue(report['failures'])
        report=b.summarize([good|{'size_bytes':4096}])
        self.assertTrue(report['failures'])
    def test_corrupt_ledger_never_resets_budget(self):
        from ledger import Ledger
        path=Path(tempfile.mkdtemp(prefix='writeflow-corrupt-')).resolve()/'ledger.json'
        path.write_text('{');path.chmod(0o600)
        with self.assertRaises(Exception):
            with Ledger(path,b.make_plan()):pass
        self.assertEqual(path.read_text(),'{')
    def test_formal_report_requires_every_step_and_six_per_group(self):
        records=[]
        for s in b.make_plan()['steps']:
            small=s['workload']=='small-files-and-sync'
            records.append(dict(status='passed',run_id=s['id'],plan_step=s['id'],provider=s['provider'],cache=s['cache'],
                workload=s['workload'],size_bytes=s['size_bytes'],concurrency=s['concurrency'],seed=s['seed'],
                logical_write_bytes=s['write_budget_bytes'],fio_bytes_per_second=10,duration_seconds=1,
                fio_commit=b.PIN,ioengine='posix' if small else 'psync',iodepth=1,numjobs=1,
                fio_version='不适用-原生POSIX' if small else 'fio-test',small_file_count=10000 if small else 0,sync_policy='固定测试同步策略'))
        full=b.summarize(records)
        self.assertTrue(full['complete']);self.assertTrue(all(g['plan_samples']==6 for g in full['groups'] if g['workload'] in ['random-read','random-write']))
        self.assertFalse(b.summarize(records[:-1])['complete'])
        self.assertFalse(b.summarize([r|{'iodepth':2} for r in records])['complete'])
        self.assertFalse(b.summarize([r|{'fixture_boundary':True} for r in records])['complete'])
        damaged=records.copy();damaged[-1]=damaged[-1]|{'fio_version':'另一版本'}
        self.assertFalse(b.summarize(damaged)['complete'])
    def test_ledger_lock_and_compact_results(self):
        from ledger import Ledger
        path=Path(tempfile.mkdtemp(prefix='writeflow-exclusive-')).resolve()/'ledger.json';plan=b.make_plan()
        with Ledger(path,plan) as ledger:
            with self.assertRaises(BlockingIOError):
                with Ledger(path,plan):pass
            token=ledger.reserve(plan['steps'][0])
            ledger.finish(token,dict(status='failed',workload='small-files-and-sync',file_hashes={'x':'a'*100000},fio_json={'large':'a'*100000}))
        self.assertLess(path.stat().st_size,4096)
    def test_ledger_tally_tampering_refused(self):
        from ledger import Ledger, LedgerError
        path=Path(tempfile.mkdtemp(prefix='writeflow-tally-')).resolve()/'ledger.json';plan=b.make_plan()
        with Ledger(path,plan) as ledger:ledger.reserve(plan['steps'][0])
        data=json.loads(path.read_text());data['reserved_write_bytes']=0;path.write_text(json.dumps(data))
        with self.assertRaises(LedgerError):
            with Ledger(path,plan):pass
    def test_each_cache_has_independent_cumulative_cap(self):
        from ledger import Ledger, LedgerError
        plan=b.make_plan();plan['cache_limit_bytes']=plan['steps'][0]['write_budget_bytes']
        path=Path(tempfile.mkdtemp(prefix='writeflow-cache-cap-')).resolve()/'ledger.json'
        with Ledger(path,plan) as ledger:
            token=ledger.reserve(plan['steps'][0]);ledger.finish(token,{'status':'failed'})
            with self.assertRaises(LedgerError):ledger.reserve(plan['steps'][0])
            self.assertEqual(ledger.data['reserved_by_cache']['buffered'],plan['steps'][0]['write_budget_bytes'])
    def test_outer_isolation_requires_full_bound_proof(self):
        root=Path(tempfile.mkdtemp(prefix='writeflow-anchor-')).resolve();root.chmod(0o700)
        session=root/'new';session.mkdir(mode=0o777);session.chmod(0o777)
        fd=os.open(session,os.O_RDONLY|os.O_DIRECTORY);self.addCleanup(os.close,fd)
        a=root.stat();d=session.stat()
        state=dict(provider='blntfs',mount_owner_uid=os.getuid(),mount_identity='mount',mount_point=str(session),source='/dev/disk99',directory_device=d.st_dev,directory_inode=d.st_ino)
        proof=dict(schema=1,isolation_kind='direct-uid',caller_uid=os.getuid(),path=str(root),device=a.st_dev,inode=a.st_ino,uid=os.getuid(),mode=0o700,identity='parent',mount_identity='mount',mount_point=str(session),source='/dev/disk99',same_mount_count=1)
        with self.assertRaises(b.Refusal):b.open_isolation(fd,session,state)
        held=b.open_isolation(fd,session,state|{'isolation':proof});os.close(held)
        for change in [{'uid':0},{'mode':0o777},{'inode':0},{'mount_identity':'other'},{'same_mount_count':2},{'identity':'mount'}]:
            with self.subTest(change=change),self.assertRaises(b.Refusal):b.open_isolation(fd,session,state|{'isolation':proof|change})
    def test_official_time_resources_and_own_group_timeout(self):
        from workloads import run_measured
        import subprocess,time
        result,resources=run_measured(['/usr/bin/true'],timeout=5,capture_output=True)
        self.assertEqual(result.returncode,0);self.assertGreater(resources['maximum_resident_set_bytes'],0)
        self.assertGreaterEqual(resources['user_cpu_seconds'],0)
        at=time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):run_measured(['/bin/sleep','2'],timeout=0.05,capture_output=True)
        self.assertLess(time.monotonic()-at,1)
    def test_helper_isolation_rejects_forged_namespace_uid_and_owner(self):
        root=Path(tempfile.mkdtemp(prefix='writeflow-helper-proof-')).resolve();root.chmod(0o777)
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY);self.addCleanup(os.close,fd)
        st=os.fstat(fd);anchor=b.HELPER_NAMESPACE+'/'+str(os.getuid())
        token='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';mount=anchor+'/'+token+'/volume'
        state=dict(provider='blntfs',mount_identity='m',mount_point=mount,source='/dev/disk99',mount_owner_uid=0,directory_device=st.st_dev,directory_inode=st.st_ino)
        proof=dict(schema=1,isolation_kind='helper-root-acl',path=anchor,device=st.st_dev,inode=123,uid=0,caller_uid=os.getuid(),mode=0o700,identity='apfs',mount_identity='m',mount_point=mount,source='/dev/disk99',same_mount_count=1)
        for change in [{'path':str(root)},{'uid':os.getuid()},{'caller_uid':os.getuid()+1},{'mode':0o755}]:
            with self.subTest(change=change),self.assertRaises(b.Refusal):b.open_isolation(fd,Path(mount)/'test',state|{'isolation':proof|change})
        with self.assertRaises(b.Refusal):b.open_isolation(fd,Path(mount)/'test',state|{'mount_owner_uid':os.getuid(),'isolation':proof})
    def test_private_mode_cannot_hide_an_extra_acl(self):
        root=Path(tempfile.mkdtemp(prefix='writeflow-mode-acl-')).resolve();root.chmod(0o700)
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY);self.addCleanup(os.close,fd)
        st=os.fstat(fd)
        with self.assertRaises(b.Refusal):b.open_isolation(fd,root,dict(directory_empty_acl=False,directory_device=st.st_dev,directory_inode=st.st_ino))
        with self.assertRaises(b.Refusal):b.open_isolation(fd,root,dict(directory_empty_acl=True,mount_owner_uid=0,directory_device=st.st_dev,directory_inode=st.st_ino))
    @unittest.skipUnless(os.environ.get('WRITEFLOW_FIO_SMOKE'),'显式本机构建fio才执行')
    def test_default_small_file_report_round_trips_into_ro_verification(self):
        fio=Path(os.environ['WRITEFLOW_FIO_SMOKE']).resolve();root=Path(tempfile.mkdtemp(prefix='writeflow-small-ro-')).resolve()
        state=dict(provider='blntfs',media_id=101,capacity=1024**3,internal=False,virtual=False,read_only=False,
                   mount_identity='fixture-only',source='/dev/disk99',mount_point=str(root))
        args=SimpleNamespace(output=str(root/'source.json'),target=str(root),probe='fixture',fio=str(fio),fio_manifest=str(fio.parent.parent/'fio-build.json'),
            expect_provider='blntfs',expect_media_id=101,expect_capacity=1024**3,size_mib=4,budget_mib=4,direct=False,step=None,
            timeout=30,workload='small-files-and-sync',concurrency=1,source_report=None,ledger=None,small_file_count=256)
        with patch.object(b,'probe',side_effect=lambda binary,path:fixture_probe(state,path)):source=b.execute(args)
        self.assertEqual(source['status'],'passed',source.get('reason'));b.validate_source_report(source)
        self.assertEqual(source['size_bytes'],256*4096)
        state['read_only']=True
        with patch.object(b,'probe',side_effect=lambda binary,path:fixture_probe(state,path)):
            verified=b.verify_owned_workset(root,source,fixture_probe(state,root),'fixture','blntfs',101,1024**3)
        self.assertEqual(verified['status'],'passed',verified.get('reason'));self.assertEqual(len(verified['files']),256)
        self.assertEqual(verified['verified_bytes'],256*4096)
        print('独立默认小文件→只读复核构造边界证据：'+str(root))
    @unittest.skipUnless(os.environ.get('WRITEFLOW_FIO_SMOKE'),'显式本机构建fio才执行')
    def test_formal_step_ledger_host_fixture(self):
        fio=Path(os.environ['WRITEFLOW_FIO_SMOKE']).resolve();root=Path(tempfile.mkdtemp(prefix='writeflow-formal-micro-')).resolve()
        plan=b.make_plan();selected=[dict(s) for s in plan['steps'] if s['id'] in ['step-005','step-006']]
        for s in selected:s['size_bytes']=1024**2;s['write_budget_bytes']=1024**2 if s['workload']=='sequential-write' else 0
        self.assertEqual(len(selected),2);plan['steps']=selected;plan['limit_bytes']=4*1024**2
        state=dict(provider='blntfs',media_id=101,capacity=1024**3,internal=False,virtual=False,read_only=False,mount_identity='fixture-only')
        for step in selected:
            args=SimpleNamespace(output=str(root/(step['id']+'.json')),target=str(root),probe='fixture',fio=str(fio),fio_manifest=str(fio.parent.parent/'fio-build.json'),expect_provider='blntfs',expect_media_id=101,expect_capacity=1024**3,size_mib=1,budget_mib=4,direct=False,step=step['id'],timeout=30,ledger=str(root/'ledger.json'))
            with patch.object(b,'probe',side_effect=lambda binary,path:fixture_probe(state,path)),patch.object(b,'make_plan',return_value=plan):r=b.execute(args)
            self.assertEqual(r['status'],'passed',r.get('reason'))
            b.validate_source_report(r)
            r['fixture_boundary']=True;Path(args.output).write_text(json.dumps(r,ensure_ascii=False,indent=2))
        self.assertEqual(json.loads((root/'ledger.json').read_text())['reserved_write_bytes'],1024**2)
        print('累计账本内盘微型计划证据：'+str(root))
    @unittest.skipUnless(os.environ.get('WRITEFLOW_FIO_SMOKE'),'显式本机构建fio才执行')
    def test_all_real_workloads_host_fixture(self):
        fio=Path(os.environ['WRITEFLOW_FIO_SMOKE']).resolve()
        root=Path(tempfile.mkdtemp(prefix='writeflow-all-workloads-')).resolve()
        state=dict(provider='blntfs',media_id=101,capacity=1024**3,internal=False,virtual=False,read_only=False,mount_identity='fixture-only')
        previous={}
        for workload,concurrency in [('sequential-write',1),('sequential-read',1),('random-initialize',1),('random-write',1),('random-read',1),('random-initialize',4),('random-write',4),('random-read',4),('small-files-and-sync',1)]:
            key='sequential' if workload.startswith('sequential') else 'random'+str(concurrency)
            source=previous.get(key)
            args=SimpleNamespace(output=str(root/(workload+str(concurrency)+'.json')),target=str(root),probe='fixture',fio=str(fio),fio_manifest=str(fio.parent.parent/'fio-build.json'),expect_provider='blntfs',expect_media_id=101,expect_capacity=1024**3,size_mib=1,budget_mib=4,direct=False,step=None,timeout=30,workload=workload,concurrency=concurrency,source_report=source,ledger=None,small_file_count=8)
            with patch.object(b,'probe',side_effect=lambda binary,path:fixture_probe(state,path)):r=b.execute(args)
            self.assertEqual(r['status'],'passed',r.get('reason'))
            b.validate_source_report(r)
            r['fixture_boundary']=True
            Path(args.output).write_text(json.dumps(r,ensure_ascii=False,indent=2))
            previous[key]=args.output
            self.assertTrue(r['file_hashes'])
            self.assertGreater(r['resources']['maximum_resident_set_bytes'],0)
            if workload!='small-files-and-sync':self.assertEqual(len(r['fio_cpu_jobs']),concurrency)
            self.assertLessEqual(r['logical_write_bytes'],4*1024**2)
        print('所有负载内盘构造边界证据：'+str(root))
