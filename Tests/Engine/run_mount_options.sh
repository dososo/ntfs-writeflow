#!/bin/bash
# 仅在新建普通文件镜像中验证生产选项与生命周期；不挂载、不使用设备或系统服务。
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
OUT="$(mktemp -d "$ROOT/build/0.3.1-vm/挂载选项回归-XXXXXXXX")"
BASE=ThirdParty/FSKitAdapter
for ARCH in "${ARCHITECTURES[@]}"; do
  ENGINE="build/engine/$ARCH"
  [[ -f "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" ]] || { echo '缺少固定版本对应架构的引擎，请先本地构建。' >&2; exit 1; }
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
    -Dnfsk_sync=nfsk_sync_real -Dnfsk_umount=nfsk_umount_real -Dnfsk_quick_check=nfsk_quick_check_real \
    -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
    -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge-$ARCH.o"
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -I ThirdParty/NTFSBridge \
    -c "$BASE/Tests/lifecycle_faults.c" -o "$OUT/faults-$ARCH.o"
  xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -fobjc-arc -fmodules \
    -I ThirdParty/NTFSBridge -c "$BASE/ntfs_device_fskit.m" -o "$OUT/backend-$ARCH.o"
  for TEST in policy_checks activation_lifecycle legacy_activation; do
    xcrun swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.4" \
      -import-objc-header "$BASE/Tests/lifecycle_bridging.h" -I ThirdParty/NTFSBridge \
      "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
      "$BASE/Tests/$TEST.swift" "$OUT/bridge-$ARCH.o" "$OUT/faults-$ARCH.o" "$OUT/backend-$ARCH.o" \
      "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" -framework FSKit -framework Foundation \
      -framework CoreFoundation -o "$OUT/$TEST-$ARCH"
  done
  arch "-$ARCH" "$OUT/policy_checks-$ARCH" > "$OUT/策略-$ARCH.log" 2>&1
  IMAGE="$OUT/普通卷-$ARCH.img"
  INVALID="$OUT/无效卷-$ARCH.img"
  python3 - "$IMAGE" "$INVALID" <<'PY'
import sys
for name in sys.argv[1:]:
    with open(name, 'xb') as stream:
        stream.truncate(64 * 1024 * 1024)
PY
  "$ENGINE/ntfsprogs/mkntfs" -F -Q -L MountOptions "$IMAGE" > "$OUT/格式化-$ARCH.log" 2>&1
  arch "-$ARCH" "$OUT/activation_lifecycle-$ARCH" "$IMAGE" "$INVALID" > "$OUT/生命周期-$ARCH.log" 2>&1
  arch "-$ARCH" "$OUT/legacy_activation-$ARCH" "$IMAGE" "$INVALID" > "$OUT/旧激活-$ARCH.log" 2>&1
  "$ENGINE/ntfsprogs/ntfscat" "$IMAGE" '/挂载参数中文目录/中文内容.txt' > "$OUT/独立复读-$ARCH.txt"
  printf '仅挂载阶段显式读写' > "$OUT/预期内容-$ARCH.txt"
  cmp "$OUT/独立复读-$ARCH.txt" "$OUT/预期内容-$ARCH.txt"
  "$ENGINE/ntfsprogs/ntfscat" "$IMAGE" '/旧激活中文目录/中文内容.txt' > "$OUT/旧激活独立复读-$ARCH.txt"
  printf '无mount回调仍须完整写前门禁' > "$OUT/旧激活预期内容-$ARCH.txt"
  cmp "$OUT/旧激活独立复读-$ARCH.txt" "$OUT/旧激活预期内容-$ARCH.txt"
done
echo "挂载选项与真实引擎生命周期回归通过：$OUT"
