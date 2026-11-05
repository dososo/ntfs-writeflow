#!/bin/bash
# 仅使用全新普通镜像，编译真实生产桥；不挂载、不安装、不操作设备。
set -euo pipefail
[[ $# -eq 0 ]] || { echo '此测试不接受外部镜像或设备参数。' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
case "${NTFS_TEST_ARCH:-universal}" in
  arm64|x86_64) ARCHITECTURES=("$NTFS_TEST_ARCH");;
  universal) ARCHITECTURES=(arm64 x86_64);;
  *) echo '测试架构仅支持arm64、x86_64、universal。' >&2; exit 2;;
esac
mkdir -p build/0.3.1-vm
OUT="$(mktemp -d "$ROOT/build/0.3.1-vm/特殊项回归-XXXXXXXX")"
BASE=ThirdParty/FSKitAdapter
for ARCH in "${ARCHITECTURES[@]}"; do
  ENGINE="build/engine/$ARCH"
  [[ -f "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" ]] || { echo '请先构建固定版本对应架构引擎。' >&2; exit 1; }
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
    -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
    "$BASE/Tests/special_items.c" "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" \
    -framework CoreFoundation -o "$OUT/special-$ARCH"
  IMAGE="$OUT/$ARCH.img"
  python3 -c 'import sys; f=open(sys.argv[1],"xb"); f.truncate(64*1024*1024); f.close()' "$IMAGE"
  "$ENGINE/ntfsprogs/mkntfs" -F -Q -L SpecialItems "$IMAGE" > "$OUT/格式化-$ARCH.log" 2>&1
  arch "-$ARCH" "$OUT/special-$ARCH" "$IMAGE" "$OUT/特殊项inode-$ARCH.json" > "$OUT/引擎-$ARCH.log" 2>&1
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
    -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
    -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge-$ARCH.o"
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -fobjc-arc -fmodules \
    -I ThirdParty/NTFSBridge -c "$BASE/ntfs_device_fskit.m" -o "$OUT/backend-$ARCH.o"
  xcrun swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.4" \
    -import-objc-header "$BASE/ntfs3g-Bridging-Header.h" -I ThirdParty/NTFSBridge \
    "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
    "$BASE/Tests/special_items.swift" "$OUT/bridge-$ARCH.o" "$OUT/backend-$ARCH.o" \
    "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" -framework FSKit -framework Foundation \
    -framework CoreFoundation -o "$OUT/volume-$ARCH"
  arch "-$ARCH" "$OUT/volume-$ARCH" "$IMAGE" "$OUT/特殊项inode-$ARCH.json" > "$OUT/FSVolume-$ARCH.log" 2>&1
done
echo "特殊项真实引擎回归通过：$OUT"
