"""架构参数必须在任何依赖或构建动作之前拒绝未知值。"""
import os
from pathlib import Path
import subprocess
import unittest


class EngineArchitectureTests(unittest.TestCase):
    def test_unknown_architecture_is_rejected(self):
        root = Path(__file__).resolve().parents[1]
        environment = dict(os.environ, NTFS_BUILD_ARCH="unsupported-test-architecture")
        result = subprocess.run(["bash", "script/build_engine.sh"], cwd=root,
                                env=environment, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 2)
        self.assertIn("NTFS_BUILD_ARCH", result.stderr)


if __name__ == "__main__":
    unittest.main()
