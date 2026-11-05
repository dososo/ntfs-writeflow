#!/bin/bash
# 只嵌入本次指定架构的兼容前端，不安装外部运行时。
set -euo pipefail
ROOT="${SRCROOT:?}"
OUTPUT="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Library/HelperTools/NTFSWriteFlowLegacy"
INPUTS=()
for BUILD_ARCH in ${ARCHS:?}; do
  case "$BUILD_ARCH" in arm64|x86_64) ;; *) echo '不支持的兼容前端架构。' >&2; exit 2 ;; esac
  FILE="$ROOT/build/legacy/$BUILD_ARCH/NTFSWriteFlowLegacy"
  [[ -f "$FILE" ]] || { echo '缺少本架构兼容前端，请从script/build_and_run.sh构建。' >&2; exit 1; }
  INPUTS+=("$FILE")
done
mkdir -p "$(dirname "$OUTPUT")"
xcrun lipo -create "${INPUTS[@]}" -output "$OUTPUT"
chmod 755 "$OUTPUT"
