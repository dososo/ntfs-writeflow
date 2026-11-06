#!/bin/bash
# 仅结构及公开属性回归；普通镜像不挂载、不注册扩展、不访问设备。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ENGINE_ROOT="${NTFS_TEST_ENGINE_ROOT:?请设置固定引擎构建目录NTFS_TEST_ENGINE_ROOT}"
MODE="${1:---structure}"
[[ $# -le 1 && ( "$MODE" == --structure || "$MODE" == --validity ) ]] || exit 2
case "${NTFS_TEST_ARCH:-universal}" in
arm64|x86_64) ARCHS=("$NTFS_TEST_ARCH");;
universal) ARCHS=(arm64 x86_64);;
*) exit 2;;
esac
mkdir -p build/0.3.1-vm
OUT="$(mktemp -d "$ROOT/build/0.3.1-vm/旧KOIO隔离回归-XXXXXXXX")"
printf '%s\n' "$OUT"
BASE=ThirdParty/FSKitAdapter
TEST=legacy_koio_structure
[[ "$MODE" == --validity ]] && TEST=legacy_koio_validity
for ARCH in "${ARCHS[@]}"; do
 ENGINE="$ENGINE_ROOT/$ARCH"
 xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
   -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
   -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge-$ARCH.o"
 xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -I ThirdParty/NTFSBridge \
   -c "$BASE/ntfs_device_fskit.m" -o "$OUT/backend-$ARCH.o"
 xcrun swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.4" \
   -import-objc-header "$BASE/ntfs3g-Bridging-Header.h" -I ThirdParty/NTFSBridge \
   "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
   "$BASE/Tests/$TEST.swift" "$OUT/bridge-$ARCH.o" "$OUT/backend-$ARCH.o" \
   "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" -framework FSKit -framework Foundation \
   -framework CoreFoundation -o "$OUT/$TEST-$ARCH"
 IMAGE="$OUT/只读普通镜像-$ARCH.img"
 python3 - "$IMAGE" <<'PY'
import sys
with open(sys.argv[1],'xb') as f:f.truncate(64*1024*1024)
PY
 "$ENGINE/ntfsprogs/mkntfs" -F -Q -L LegacyKOIO "$IMAGE" > "$OUT/格式化-$ARCH.log" 2>&1
 python3 - "$OUT/$TEST-$ARCH" "$ARCH" "$IMAGE" "$ROOT/Configuration/FileSystem-Info.plist" "$OUT/运行-$ARCH.log" "$MODE" <<'PY'
import subprocess,sys
command=['arch','-'+sys.argv[2],sys.argv[1],sys.argv[3]]
if sys.argv[6]=='--structure':command.append(sys.argv[4])
with open(sys.argv[5],'xb') as f:r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT)
with open(sys.argv[5]+'.exit','x') as f:f.write(str(r.returncode)+'\n')
if r.returncode:raise SystemExit('回归失败，退出码：'+str(r.returncode)+'；日志：'+sys.argv[5])
PY
done
echo "旧系统KOIO隔离回归通过：$OUT"
