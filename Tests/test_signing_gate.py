"""只使用内存字典测试描述文件拒绝逻辑，不制作或安装描述文件。"""
import datetime
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("signing", Path(__file__).parents[1] / "script/check_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningGateTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            "Name": "内存测试数据", "TeamIdentifier": ["TESTTEAM"], "Platform": ["OSX"],
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=1),
            "ProvisionsAllDevices": True, "DeveloperCertificates": ["测试证书".encode()],
            "Entitlements": {
                "com.apple.application-identifier": "TESTTEAM." + signing.BUNDLE_ID,
                signing.MODULE_ENTITLEMENT: True,
            },
        }

    def inspect(self, certificate="测试证书".encode()):
        result = subprocess.CompletedProcess([], 0, plistlib.dumps(self.profile), b"")
        with patch.object(signing.subprocess, "run", return_value=result):
            return signing.inspect_profile(Path("内存样本"), certificate)

    def test_matching_certificate(self):
        self.assertTrue(self.inspect()["匹配"])
        self.assertTrue(self.inspect()["选用证书已核验"])

    def test_other_certificate_same_team_rejected(self):
        self.assertFalse(self.inspect(b"another")["匹配"])

    def test_device_limited_profile_rejected(self):
        self.profile["ProvisionedDevices"] = ["其他设备"]
        self.assertFalse(self.inspect()["匹配"])

    def test_development_profile_rejected(self):
        self.profile["Entitlements"]["get-task-allow"] = True
        self.assertFalse(self.inspect()["匹配"])

    def test_missing_capability_rejected(self):
        del self.profile["Entitlements"][signing.MODULE_ENTITLEMENT]
        self.assertFalse(self.inspect()["匹配"])

    def test_other_application_rejected(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "TESTTEAM.other"
        self.assertFalse(self.inspect()["匹配"])

    def test_expired_profile_rejected(self):
        self.profile["ExpirationDate"] = datetime.datetime.now() - datetime.timedelta(days=1)
        self.assertFalse(self.inspect()["匹配"])

    def test_no_certificate_not_claimed_verified(self):
        self.assertFalse(self.inspect(None)["选用证书已核验"])


if __name__ == "__main__":
    unittest.main()
