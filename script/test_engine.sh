#!/usr/bin/env bash
# 只在新建目录中的普通文件镜像上运行测试，不接受外部镜像或设备参数。
set -euo pipefail
[[ $# -eq 0 ]] || { printf '此测试不接受外部镜像或设备参数。\n' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/验证/引擎"
./script/build_engine.sh > "$ROOT/验证/引擎/构建日志.txt" 2>&1
xcrun clang -arch arm64 -g -DHAVE_CONFIG_H=1 \
  -I"$ROOT/build/engine/arm64" -I"$ROOT/ThirdParty/ntfs-3g/include" \
  -I"$ROOT/ThirdParty/NTFSBridge" \
  "$ROOT/Tests/Engine/image_roundtrip.c" "$ROOT/ThirdParty/NTFSBridge/ntfs_fskit.c" \
  "$ROOT/build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation -o "$ROOT/build/engine/镜像闭环测试"
python3 "$ROOT/Tests/Engine/verify_roundtrip.py"
