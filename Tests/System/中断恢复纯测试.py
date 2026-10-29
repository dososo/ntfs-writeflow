"""无设备操作：检查握手、精确子进程终止和既有镜像清理拒绝边界。"""
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import unittest
import io

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('interrupt_probe', HERE/'中断恢复验收.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class Checkpoints(unittest.TestCase):
    def setUp(self):
        self.good = {'kind':'checkpoint','pid':100,'token':'our-token','phase':'before-event'}
    def test_only_exact_owned_process_checkpoint_is_accepted(self):
        self.assertTrue(probe.checkpoint_matches(self.good,100,'our-token','before-event'))
        for key,value in [('pid',101),('token','other'),('phase','record-pending'),('kind','result')]:
            invalid=dict(self.good,**{key:value})
            self.assertFalse(probe.checkpoint_matches(invalid,100,'our-token','before-event'),key)
    def test_unknown_phase_or_missing_pid_is_rejected(self):
        self.assertFalse(probe.checkpoint_matches(dict(self.good,phase='arbitrary'),100,'our-token','arbitrary'))
        self.assertFalse(probe.checkpoint_matches({'token':'our-token'},100,'our-token','before-event'))

class OwnedProcesses(unittest.TestCase):
    def child(self):
        script = "import os,json,time; print(json.dumps(dict(kind='checkpoint',pid=os.getpid(),token='our-token',phase='before-event')),flush=True);time.sleep(60)"
        return subprocess.Popen([sys.executable,'-u','-c',script],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def test_real_owned_process_is_killed_only_after_exact_handshake(self):
        child=self.child()
        try:
            packet=probe.wait_checkpoint(child,'our-token','before-event',timeout=2)
            self.assertIsNotNone(packet,'尚未提供真实检查点等待')
            self.assertEqual(probe.terminate_owned(child,packet,'our-token','before-event'),-9)
            self.assertIsNotNone(child.poll())
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=3)
            child.stdout.close();child.stderr.close()
    def test_output_limit_is_bounded_before_json_parsing(self):
        child=subprocess.Popen([sys.executable,'-u','-c',"import sys,time;sys.stdout.write('x'*70000);sys.stdout.flush();time.sleep(60)"],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            with self.assertRaisesRegex(RuntimeError,'输出超限'):
                probe.wait_checkpoint(child,'our-token','before-event',timeout=2)
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=3)
            child.stdout.close();child.stderr.close()
    def test_missing_checkpoint_times_out_without_hanging(self):
        import time
        child=subprocess.Popen([sys.executable,'-u','-c','import time;time.sleep(60)'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            start=time.monotonic()
            self.assertRaises(RuntimeError,probe.wait_checkpoint,child,'our-token','before-event',timeout=0.05)
            self.assertLess(time.monotonic()-start,0.6)
            self.assertIsNone(child.poll())
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=3)
            child.stdout.close();child.stderr.close()
    def test_mismatched_handshake_never_kills_child(self):
        child=self.child()
        try:
            self.assertRaises(RuntimeError,probe.terminate_owned,child,dict(kind='checkpoint',pid=child.pid+1,token='our-token',phase='before-event'),'our-token','before-event')
            self.assertIsNone(child.poll())
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=3)
            child.stdout.close();child.stderr.close()
    def test_malformed_handshake_preserves_raw_evidence(self):
        child=subprocess.Popen([sys.executable,'-u','-c',"import sys,time;print('invalid-json',flush=True);time.sleep(60)"],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        evidence=io.BytesIO()
        try:
            with self.assertRaises(json.JSONDecodeError):
                probe.wait_checkpoint(child,'our-token','before-event',timeout=2,evidence=evidence)
            self.assertEqual(evidence.getvalue(),b'invalid-json\n')
            self.assertIsNone(child.poll())
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=3)
            child.stdout.close();child.stderr.close()

class ImageIdentity(unittest.TestCase):
    def fake(self,physical=False,capacity=128*1024*1024,entries=1,device='/dev/disk999'):
        def run(command):
            if command[:3]==['/usr/bin/hdiutil','info','-plist']:
                return plistlib.dumps({'images':[{'image-path':'/private/tmp/own-interrupt.img','system-entities':[{'dev-entry':device}]} for _ in range(entries)]})
            if command[:3]==['/usr/sbin/diskutil','info','-plist']:
                return plistlib.dumps({'VirtualOrPhysical':'Physical' if physical else 'Virtual','IOKitSize':capacity})
            raise AssertionError('不允许测试发生其他命令')
        return run
    def test_exact_virtual_mapping_is_observed_without_operations(self):
        device,info=probe.verified_mapping('/private/tmp/own-interrupt.img',128*1024*1024,self.fake())
        self.assertEqual(device,'/dev/disk999');self.assertEqual(info['VirtualOrPhysical'],'Virtual')
    def test_physical_capacity_duplicate_and_partition_are_rejected(self):
        for kwargs in [dict(physical=True),dict(capacity=64),dict(entries=2),dict(device='/dev/disk999s1')]:
            with self.subTest(kwargs=kwargs):
                self.assertRaises(RuntimeError,probe.verified_mapping,'/private/tmp/own-interrupt.img',128*1024*1024,self.fake(**kwargs))
    def test_different_image_path_is_rejected(self):
        self.assertRaises(RuntimeError,probe.verified_mapping,'/private/tmp/different.img',128*1024*1024,self.fake())
    def test_checkpoint_state_never_accepts_unexpected_mount(self):
        packet=dict(mount_point='/private/tmp/owned',provider='blntfs')
        for phase in ['before-event','record-pending']:
            self.assertEqual(probe.inspect_checkpoint_state(phase,packet,{}),'未挂载')
            self.assertRaises(RuntimeError,probe.inspect_checkpoint_state,phase,packet,{'MountPoint':'/other'})
        self.assertRaises(RuntimeError,probe.inspect_checkpoint_state,'mount-confirmed',packet,{'MountPoint':'/other'})
        self.assertRaises(RuntimeError,probe.inspect_checkpoint_state,'mount-confirmed',dict(packet,provider='other'),{'MountPoint':'/private/tmp/owned'})
        self.assertIn('已挂载',probe.inspect_checkpoint_state('mount-confirmed',packet,{'MountPoint':'/private/tmp/owned'}))

if __name__=='__main__':
    unittest.main()
