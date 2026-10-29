import importlib.util
import os
import json
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location('benchmark',Path(__file__).with_name('benchmark.py'))
benchmark=importlib.util.module_from_spec(spec);spec.loader.exec_module(benchmark)

def fixture_probe(state,path):
    st=Path(path).stat()
    return dict(mount_owner_uid=os.getuid())|state|dict(directory_empty_acl=True,directory_device=st.st_dev,directory_inode=st.st_ino)

class BenchTests(unittest.TestCase):
    def test_plan(self):
        plan=benchmark.make_plan()
        self.assertEqual(plan['maximum_write_bytes'],1008*1024**3)
        self.assertLessEqual(plan['maximum_write_bytes'],plan['limit_bytes'])
        self.assertEqual(sum(x['write_budget_bytes'] for x in plan['steps']),plan['maximum_write_bytes'])
        seq=[x for x in plan['steps'] if x['workload']=='sequential-write']
        self.assertEqual(len(seq),24)
        self.assertEqual([x['provider'] for x in seq[:4]],['blntfs','ufsd_NTFS','ufsd_NTFS','blntfs'])
    def test_identity(self):
        state={'provider':'blntfs','media_id':101,'capacity':1024**3,'internal':False,'virtual':False,'read_only':False}
        benchmark.validate_target(state,'blntfs',101,1024**3)
        for change in [{'provider':'ntfs'},{'media_id':102},{'capacity':1},{'internal':True},{'virtual':True},{'read_only':True}]:
            with self.subTest(change=change),self.assertRaises(benchmark.Refusal):
                benchmark.validate_target(state|change,'blntfs',101,1024**3)
    def test_no_raw_or_symlink(self):
        with self.assertRaises(benchmark.Refusal):benchmark.validate_path(Path('/dev/rdisk7'))
        d=tempfile.mkdtemp(prefix='writeflow-symlink-')
        root=Path(d).resolve();(root/'link').symlink_to(root,target_is_directory=True)
        with self.assertRaises(benchmark.Refusal):benchmark.validate_path(root/'link')
    def test_budget_refusal_preserves_report_without_workload(self):
        d=tempfile.mkdtemp(prefix='writeflow-reject-')
        root=Path(d).resolve();out=root/'result.json'
        args=SimpleNamespace(output=str(out),target=str(root),probe='unused',fio='unused',fio_manifest='unused',expect_provider='blntfs',expect_media_id=101,expect_capacity=1024**3,size_mib=4,budget_mib=1,direct=False,step=None,timeout=1)
        state={'provider':'blntfs','media_id':101,'capacity':1024**3,'internal':False,'virtual':False,'read_only':False}
        with patch.object(benchmark,'probe',side_effect=lambda binary,path:fixture_probe(state,path)):result=benchmark.execute(args)
        self.assertEqual(result['status'],'failed');self.assertIn('预算',result['reason'])
        self.assertTrue(out.is_file());self.assertEqual(list(root.glob('WriteFlow-Benchmark-*')),[])
    def test_report_does_not_mix_sizes_or_duplicate_runs(self):
        def sample(run,size):return {'status':'passed','run_id':run,'provider':'blntfs','workload':'sequential-write','cache':'buffered','fio_bytes_per_second':10,'duration_seconds':1,'size_bytes':size}
        report=benchmark.summarize([sample('a',4),sample('b',32),sample('a',4)])
        self.assertEqual(len(report['groups']),2);self.assertEqual(len(report['failures']),1);self.assertFalse(report['complete'])
    @unittest.skipUnless(os.environ.get('WRITEFLOW_FIO_SMOKE'), '仅显式设置本地fio后运行host 4MiB构造边界smoke')
    def test_real_fio_host_fixture(self):
        fio=Path(os.environ['WRITEFLOW_FIO_SMOKE']).resolve()
        manifest=fio.parent.parent/'fio-build.json'
        parent=tempfile.mkdtemp(prefix='writeflow-fio-host-fixture-')
        root=Path(parent).resolve();out=root/'result.json'
        args=SimpleNamespace(output=str(out),target=str(root),probe='fixture-only',fio=str(fio),fio_manifest=str(manifest),expect_provider='blntfs',expect_media_id=101,expect_capacity=1024**3,size_mib=4,budget_mib=4,direct=False,step=None,timeout=30)
        state={'provider':'blntfs','media_id':101,'capacity':1024**3,'internal':False,'virtual':False,'read_only':False,'mount_identity':'fixture-only'}
        with patch.object(benchmark,'probe',side_effect=lambda binary,path:fixture_probe(state,path)):result=benchmark.execute(args)
        self.assertEqual(result['status'],'passed',result.get('reason'));self.assertEqual(result['logical_write_bytes'],4*1024**2)
        self.assertEqual(len(result['sha256']),64);self.assertFalse(benchmark.summarize([result])['complete'])
        result['fixture_boundary']=True
        # 所有生成文件保留在host专属目录，退出此测试不自动批量删除。
        evidence=Path(__file__).resolve().parents[2]/'build/0.2.0/性能单步-host-fixture.json'
        evidence.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    def test_report(self):
        report=benchmark.summarize([{'status':'failed','reason':'EIO'},{'status':'passed','provider':'blntfs','workload':'sequential-write','cache':'buffered','fio_bytes_per_second':10,'duration_seconds':1}])
        self.assertFalse(report['complete']);self.assertEqual(len(report['failures']),1)
        self.assertEqual(report['groups'][0]['samples'],1)
        self.assertEqual(report['groups'][0]['median_bytes_per_second'],10)
        self.assertFalse(benchmark.summarize([])['complete'])

if __name__=='__main__':unittest.main()
