#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
CONFIGURATION="${NTFS_BUILD_CONFIGURATION:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo '构建配置仅支持 Debug 或 Release。' >&2; exit 2 ;;
esac
case "$MODE" in
  run|--build-only|--verify|--logs|--telemetry|--debug) ;;
  *) echo '用法：script/build_and_run.sh [--build-only|--verify|--logs|--telemetry|--debug]' >&2; exit 2 ;;
esac
mkdir -p build/日志
if [[ "$MODE" != --build-only ]]; then
  pkill -x NTFSWorkbench >/dev/null 2>&1 || true
fi
./script/build_engine.sh > build/日志/引擎构建.log 2>&1
xcodegen generate --spec project.yml > build/日志/工程生成.log 2>&1
if ! xcodebuild -project NTFSWorkbench.xcodeproj -scheme NTFSWorkbench \
  -configuration "$CONFIGURATION" -derivedDataPath build/xcode \
  CODE_SIGNING_ALLOWED=NO build > build/日志/应用构建.log 2>&1; then
  echo '构建失败，详见 build/日志/应用构建.log。' >&2
  tail -60 build/日志/应用构建.log >&2
  exit 1
fi
APP="$ROOT_DIR/build/xcode/Build/Products/$CONFIGURATION/NTFSWorkbench.app"
EXTENSION="$APP/Contents/Extensions/NTFSFileSystem.appex"
HELPER="$APP/Contents/Library/HelperTools/NTFSWriteFlowMountHelper"
# 本地诊断签名不具备 FSKit 授权，不将其当作发布或可挂载版本。
/usr/bin/codesign --force --sign - --identifier com.blteam.ntfsworkbench.mount-helper "$HELPER"
/usr/bin/codesign --force --sign - --entitlements Configuration/FileSystem.entitlements "$EXTENSION"
/usr/bin/codesign --force --sign - "$APP"
echo "构建完成：$APP"
echo '当前为临时签名开发验证版；扩展仍需匹配的 FSKit 描述文件、正式签名与用户启用。'
case "$MODE" in
  --build-only) exit 0 ;;
  --debug) exec lldb -- "$APP/Contents/MacOS/NTFSWorkbench" ;;
esac
/usr/bin/open -n "$APP"
case "$MODE" in
  --verify)
    sleep 2
    pgrep -x NTFSWorkbench >/dev/null
    echo '主应用进程已启动；这不代表扩展或读写通过。'
    ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "NTFSWorkbench" OR process == "NTFSFileSystem"'
    ;;
esac
