#!/usr/bin/env python3
"""只读核对 FSKit 描述文件；不创建证书、权限或开发者账户记录。"""
import argparse
import datetime
import json
import pathlib
import plistlib
import subprocess

BUNDLE_ID = "com.blteam.ntfsworkbench.filesystem"
MODULE_ENTITLEMENT = "com.apple.developer.fskit.fsmodule"


def inspect_profile(path, certificate=None):
    result = subprocess.run(
        ["/usr/bin/security", "cms", "-D", "-i", str(path)],
        capture_output=True, timeout=20,
    )
    if result.returncode:
        return {"文件": str(path), "匹配": False, "原因": "无法验证或解码描述文件"}
    profile = plistlib.loads(result.stdout)
    entitlements = profile.get("Entitlements", {})
    identifier = entitlements.get("com.apple.application-identifier", "")
    teams = profile.get("TeamIdentifier", [])
    expiry = profile.get("ExpirationDate")
    reasons = []
    if entitlements.get(MODULE_ENTITLEMENT) is not True:
        reasons.append("未授权 FSKit 模块")
    if not any(identifier == team + "." + BUNDLE_ID for team in teams):
        reasons.append("应用标识未精确匹配本扩展")
    if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        reasons.append("描述文件已过期或未提供有效期")
    if "OSX" not in profile.get("Platform", []):
        reasons.append("描述文件平台不是 macOS")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        reasons.append("当前签名流程只接受不限制设备的 Developer ID 分发描述文件")
    if entitlements.get("get-task-allow") is True:
        reasons.append("当前流程不接受开发调试描述文件")
    certificates = profile.get("DeveloperCertificates", [])
    if not certificates:
        reasons.append("描述文件没有授权签名证书")
    if certificate is not None and certificate not in certificates:
        reasons.append("选用证书未包含在描述文件授权集合中")
    return {
        "文件": str(path), "名称": profile.get("Name"),
        "匹配": not reasons, "原因": reasons,
        "到期": str(expiry), "团队": teams,
        "应用标识": identifier, "FSKit模块": entitlements.get(MODULE_ENTITLEMENT, False),
        "选用证书已核验": certificate is not None and certificate in certificates,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=pathlib.Path, help="指定本机描述文件路径")
    parser.add_argument("--output", type=pathlib.Path, help="保存中文 JSON 诊断")
    parser.add_argument("--certificate", type=pathlib.Path, help="用于核对授权集合的签名证书 DER 文件")
    args = parser.parse_args()
    if args.profile:
        paths = [args.profile]
    else:
        roots = [pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                 pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"]
        paths = sorted(p for root in roots if root.exists() for p in root.iterdir()
                       if p.is_file() and p.suffix in {".provisionprofile", ".mobileprovision"})
    certificate = args.certificate.read_bytes() if args.certificate else None
    profiles = [inspect_profile(path, certificate) for path in paths]
    matched = any(profile["匹配"] for profile in profiles)
    report = {
        "检查": "FSKit 描述文件前置条件", "扩展标识": BUNDLE_ID,
        "匹配描述文件": matched, "文件": profiles,
        "限制": "匹配仅证明已检查的描述文件条件；未提供证书时不证明证书授权。仍须验证扩展系统加载、用户启用和读写。",
    }
    output = json.dumps(report, ensure_ascii=False, indent=2)
    print(output)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n")
    raise SystemExit(0 if matched else 3)


if __name__ == "__main__":
    main()
