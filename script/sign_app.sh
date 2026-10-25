#!/bin/bash
# 仅处理工作区构建物；不自动注册账号能力，不安装或启用扩展。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
if [[ $# != 2 ]]; then
  echo '用法：script/sign_app.sh 描述文件绝对路径 已安装签名证书名称或指纹' >&2
  exit 2
fi
PROFILE_PATH="$1"
SIGNING_IDENTITY="$2"
python3 script/check_signing.py --profile "$PROFILE_PATH"
CONFIGURATION="${NTFS_BUILD_CONFIGURATION:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo '签名构建配置仅支持 Debug 或 Release。' >&2; exit 2 ;;
esac
SOURCE_APP="$ROOT_DIR/build/xcode/Build/Products/$CONFIGURATION/NTFSWorkbench.app"
[[ -d "$SOURCE_APP" ]] || { echo '请先运行 script/build_and_run.sh --build-only。' >&2; exit 1; }
mkdir -p build/signed
OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/build/signed/签名版本.XXXXXX")"
APP="$OUTPUT_DIR/NTFSWorkbench.app"
ditto "$SOURCE_APP" "$APP"
EXTENSION="$APP/Contents/Extensions/NTFSFileSystem.appex"
HELPER="$APP/Contents/Library/HelperTools/NTFSWriteFlowMountHelper"
[[ -f "$HELPER" ]] || { echo '构建物缺少挂载助手，停止签名。' >&2; exit 1; }
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --identifier com.blteam.ntfsworkbench.mount-helper "$HELPER"
cp "$PROFILE_PATH" "$EXTENSION/Contents/embedded.provisionprofile"
python3 - "$PROFILE_PATH" "$OUTPUT_DIR/扩展权限.plist" "$OUTPUT_DIR/预期团队.txt" <<'PY'
import pathlib,plistlib,subprocess,sys
profile=plistlib.loads(subprocess.check_output(['/usr/bin/security','cms','-D','-i',sys.argv[1]]))
source=profile['Entitlements']
team=profile['TeamIdentifier'][0]
entitlements={
 'com.apple.security.app-sandbox':True,
 'com.apple.developer.fskit.fsmodule':True,
 'com.apple.application-identifier':source['com.apple.application-identifier'],
 'com.apple.developer.team-identifier':team,
}
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
pathlib.Path(sys.argv[3]).write_text(team)
PY
# 调试构建可能含 Xcode 生成的动态库，必须与外层代码使用同一证书。
for LIBRARY in "$APP/Contents/MacOS/"*.dylib "$EXTENSION/Contents/MacOS/"*.dylib; do
  if [[ -f "$LIBRARY" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$LIBRARY"
  fi
done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --entitlements "$OUTPUT_DIR/扩展权限.plist" "$EXTENSION"
codesign --display --extract-certificates="$OUTPUT_DIR/证书-" "$EXTENSION"
python3 script/check_signing.py --profile "$PROFILE_PATH" --certificate "$OUTPUT_DIR/证书-0" \
  --output "$OUTPUT_DIR/证书授权核验.json"
/usr/bin/openssl x509 -inform DER -in "$OUTPUT_DIR/证书-0" -noout -subject > "$OUTPUT_DIR/证书主题.txt"
if ! /usr/bin/grep -q 'Developer ID Application:' "$OUTPUT_DIR/证书主题.txt"; then
  echo '当前流程只支持 Developer ID Application 分发证书，停止签名。' >&2
  exit 1
fi
codesign -dvvv "$EXTENSION" 2> "$OUTPUT_DIR/扩展签名.txt"
python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);team=(p/'预期团队.txt').read_text()
if 'TeamIdentifier='+team not in (p/'扩展签名.txt').read_text().splitlines():
 raise SystemExit('证书与描述文件团队不一致；停止，不安装此构建物。')
PY
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2> "$OUTPUT_DIR/签名结构验证.txt"
printf '已生成签名构建物：%s\n' "$APP"
echo '签名结构检查不等于扩展加载、用户启用、读写或公证通过；下一步需分别验证。'
