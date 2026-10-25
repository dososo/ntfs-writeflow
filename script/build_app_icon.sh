#!/bin/bash
# 从保留的设计原稿生成 macOS 图标包；不修改原稿。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
ICONSET="build/icons/WriteFlow.iconset"
mkdir -p "$ICONSET" Sources/App/Resources
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" 设计/NTFS畅写图标原稿.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" 设计/NTFS畅写图标原稿.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Sources/App/Resources/WriteFlow.icns
echo '已生成 Sources/App/Resources/WriteFlow.icns。'
