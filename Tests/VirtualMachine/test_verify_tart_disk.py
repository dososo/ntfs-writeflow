"""仅自建普通文件；不读取下载目录、设备或网络。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).with_name('verify_tart_disk.py')


class TartDiskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('verify_tart_disk', SCRIPT)
        cls.tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.tool)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='writeflow-raw-test-'))
        self.raw = self.root / 'disk.img'
        with self.raw.open('wb') as file:
            file.truncate(8192)
            file.seek(4096)
            file.write(b'NTFS')
        self.manifest = self.root / 'manifest.json'
        digest = 'sha256:' + 'a' * 64
        descriptor = lambda kind: {'mediaType': kind, 'size': 1, 'digest': digest}
        self.data = {'schemaVersion': 2, 'mediaType': self.tool.MANIFEST,
                     'config': descriptor(self.tool.OCI_CONFIG),
                     'annotations': {self.tool.TOTAL: '8192'}, 'layers': []}
        self.data['layers'].append(dict(descriptor(self.tool.CONFIG), annotations={}))
        for offset in (0, 4096):
            with self.raw.open('rb') as file:
                file.seek(offset)
                content = file.read(4096)
            self.data['layers'].append(dict(descriptor(self.tool.DISK), annotations={
                self.tool.SIZE: '4096', self.tool.HASH: 'sha256:' + hashlib.sha256(content).hexdigest()}))
        self.data['layers'].append(dict(descriptor(self.tool.NVRAM), annotations={}))
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.data))

    def test_sparse_file_and_ordered_ranges(self):
        before = self.raw.read_bytes()
        result = self.tool.verify(self.manifest, self.raw)
        self.assertEqual(result['结果'], '通过')
        self.assertEqual([x['偏移'] for x in result['分层']], [0, 4096])
        self.assertEqual(self.raw.read_bytes(), before)

    def test_corruption_and_wrong_size_rejected(self):
        with self.raw.open('r+b') as file:
            file.write(b'X')
        with self.assertRaises(ValueError):
            self.tool.verify(self.manifest, self.raw)
        with self.raw.open('r+b') as file:
            file.truncate(4096)
        with self.assertRaises(ValueError):
            self.tool.verify(self.manifest, self.raw)

    def test_unknown_schema_missing_layer_and_bad_annotations_rejected(self):
        for mutate in (lambda d: d.update(schemaVersion=1),
                       lambda d: d['layers'].pop(1),
                       lambda d: d['layers'][1].update(mediaType='application/vnd.cirruslabs.tart.disk.v1'),
                       lambda d: d['layers'][1]['annotations'].update({self.tool.SIZE: True}),
                       lambda d: d['layers'][1]['annotations'].update({'未知字段': '1'})):
            original = json.loads(self.manifest.read_text())
            mutate(self.data)
            self.save()
            with self.assertRaises(ValueError):
                self.tool.verify(self.manifest, self.raw)
            self.data = original
            self.save()

    def test_duplicate_json_key_rejected(self):
        self.manifest.write_text('{"schemaVersion":2,"schemaVersion":2}')
        with self.assertRaises(ValueError):
            self.tool.verify(self.manifest, self.raw)

    def test_cli_chinese_json_and_exit_status(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--manifest', str(self.manifest),
                                 '--disk', str(self.raw)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['结果'], '通过')
        result = subprocess.run([sys.executable, str(SCRIPT), '--manifest', str(self.manifest),
                                 '--disk', '/dev/null'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['结果'], '拒绝')

    def test_symlink_parent_and_device_rejected(self):
        link = self.root / 'link'
        link.symlink_to(self.raw)
        for manifest, raw in ((self.manifest, link), (link, self.raw), (self.manifest, Path('/dev/null'))):
            with self.assertRaises(ValueError):
                self.tool.verify(manifest, raw)
        parent = self.root / 'parent'
        parent.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.tool.verify(self.manifest, parent / 'disk.img')


if __name__ == '__main__':
    unittest.main()
