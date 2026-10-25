#!/usr/bin/env bash
# 仅编译与执行本地测试，不挂载或注册扩展。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
BASE=ThirdParty/FSKitAdapter
OUT="$BASE/Tests/产物"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -fmodules -fsanitize=undefined,address -g -mmacosx-version-min=26.0 \
  -I ThirdParty/NTFSBridge "$BASE/ntfs_device_fskit.m" "$BASE/Tests/backend_safety.m" \
  -framework Foundation -framework FSKit -o "$OUT/backend_safety"
"$OUT/backend_safety"
xcrun swiftc -typecheck -warnings-as-errors -swift-version 5 -target arm64-apple-macos26.0 \
  -import-objc-header "$BASE/ntfs3g-Bridging-Header.h" -I ThirdParty/NTFSBridge "$BASE"/*.swift
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -DHAVE_CONFIG_H=1 \
  -I build/engine/arm64 -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
  -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge.o"
xcrun clang -arch arm64 -fobjc-arc -fmodules -mmacosx-version-min=26.0 \
  -I ThirdParty/NTFSBridge -c "$BASE/ntfs_device_fskit.m" -o "$OUT/backend.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  -import-objc-header "$BASE/ntfs3g-Bridging-Header.h" -I ThirdParty/NTFSBridge \
  "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
  "$BASE/Tests/policy_checks.swift" "$OUT/bridge.o" "$OUT/backend.o" \
  build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a \
  -framework FSKit -framework Foundation -framework CoreFoundation -o "$OUT/policy_checks"
"$OUT/policy_checks"
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  -import-objc-header "$BASE/ntfs3g-Bridging-Header.h" -I ThirdParty/NTFSBridge \
  "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
  "$BASE/Tests/volume_roundtrip.swift" "$OUT/bridge.o" "$OUT/backend.o" \
  build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a \
  -framework FSKit -framework Foundation -framework CoreFoundation -o "$OUT/volume_roundtrip"
RUN_DIR="$(mktemp -d "$OUT/卷测试.XXXXXX")"
IMAGE="$RUN_DIR/测试卷.img"
python3 -c 'import sys; f=open(sys.argv[1],"xb"); f.truncate(64*1024*1024); f.close()' "$IMAGE"
build/engine/arm64/ntfsprogs/mkntfs -F -Q -L AdapterTest "$IMAGE" > "$RUN_DIR/格式化日志.txt" 2>&1
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -DHAVE_CONFIG_H=1 -Dnfsk_sync=nfsk_sync_real \
  -I build/engine/arm64 -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
  -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/lifecycle_bridge.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -I ThirdParty/NTFSBridge \
  -c "$BASE/Tests/lifecycle_faults.c" -o "$OUT/lifecycle_faults.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  -import-objc-header "$BASE/Tests/lifecycle_bridging.h" -I ThirdParty/NTFSBridge \
  "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
  "$BASE/Tests/activation_lifecycle.swift" "$OUT/lifecycle_bridge.o" "$OUT/lifecycle_faults.o" "$OUT/backend.o" \
  build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a \
  -framework FSKit -framework Foundation -framework CoreFoundation -o "$OUT/activation_lifecycle"
INVALID_IMAGE="$RUN_DIR/无效卷.img"
python3 -c 'import sys; f=open(sys.argv[1],"xb"); f.truncate(64*1024*1024); f.close()' "$INVALID_IMAGE"
"$OUT/activation_lifecycle" "$IMAGE" "$INVALID_IMAGE"
"$OUT/volume_roundtrip" "$IMAGE" "$RUN_DIR/预期内容.bin"
build/engine/arm64/ntfsprogs/ntfscat "$IMAGE" /完成记录.txt > "$RUN_DIR/复读内容.bin"
cmp "$RUN_DIR/预期内容.bin" "$RUN_DIR/复读内容.bin"
shasum -a 256 "$RUN_DIR/预期内容.bin" "$RUN_DIR/复读内容.bin"
printf '独立桥接复读内容一致；测试产物：%s\n' "$RUN_DIR"
