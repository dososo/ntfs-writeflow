#!/bin/bash
# 仅普通文件真实引擎测试；不调用系统挂载、注册扩展或访问设备。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ENGINE_ROOT="${NTFS_TEST_ENGINE_ROOT:?请设置NTFS_TEST_ENGINE_ROOT为固定引擎双架构构建目录}"
case "${NTFS_TEST_ARCH:-universal}" in
arm64|x86_64) ARCHS=("$NTFS_TEST_ARCH");;
universal) ARCHS=(arm64 x86_64);;
*) echo '测试架构仅允许arm64、x86_64或universal。' >&2; exit 2;;
esac
mkdir -p build/0.3.1-vm
OUT="$(mktemp -d "$ROOT/build/0.3.1-vm/就绪握手回归-XXXXXXXX")"
printf '%s\n' "$OUT"
BASE=ThirdParty/FSKitAdapter
for ARCH in "${ARCHS[@]}"; do
 ENGINE="$ENGINE_ROOT/$ARCH"
 xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 -Dnfsk_mount=nfsk_mount_real \
   -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
   -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge-$ARCH.o"
 xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -Dnfsk_block_pwrite=nfsk_block_pwrite_real \
   -Dnfsk_block_pread=nfsk_block_pread_real -Dnfsk_block_sync=nfsk_block_sync_real \
   -I ThirdParty/NTFSBridge -c "$BASE/ntfs_device_fskit.m" -o "$OUT/backend-$ARCH.o"
 xcrun clang -arch "$ARCH" -mmacosx-version-min=15.4 -DWF_READY_IO_TRACE=1 -I ThirdParty/NTFSBridge \
   -c "$BASE/Tests/koio_trace.c" -o "$OUT/trace-$ARCH.o"
 xcrun swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.4" \
   -import-objc-header "$BASE/Tests/koio_trace.h" -I ThirdParty/NTFSBridge \
   "$BASE/ntfs3gFileSystem.swift" "$BASE/ntfs3gVolume.swift" "$BASE/ntfs3gItem.swift" \
   "$BASE/Tests/write_ready.swift" "$OUT/bridge-$ARCH.o" "$OUT/backend-$ARCH.o" "$OUT/trace-$ARCH.o" \
   "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" -framework FSKit -framework Foundation \
   -framework CoreFoundation -o "$OUT/write_ready-$ARCH"
 IMAGE="$OUT/普通文件卷-$ARCH.img"
 python3 - "$IMAGE" <<'PY'
import sys
with open(sys.argv[1],'xb') as f:f.truncate(64*1024*1024)
PY
 "$ENGINE/ntfsprogs/mkntfs" -F -Q -L WriteCapability "$IMAGE" > "$OUT/格式化-$ARCH.log" 2>&1
 python3 - "$OUT/write_ready-$ARCH" "$ARCH" "$IMAGE" "$OUT/运行-$ARCH.log" <<'PY'
import subprocess,sys
with open(sys.argv[4],'xb') as f:r=subprocess.run(['arch','-'+sys.argv[2],sys.argv[1],sys.argv[3]],stdout=f,stderr=subprocess.STDOUT)
with open(sys.argv[4]+'.exit','x') as f:f.write(str(r.returncode)+'\n')
if r.returncode:raise SystemExit('普通文件回归失败，退出码：'+str(r.returncode)+'；日志：'+sys.argv[4])
PY
 "$ENGINE/ntfsprogs/ntfscat" "$IMAGE" '/就绪握手/中文内容.txt' > "$OUT/独立复读-$ARCH.txt"
 printf '只有可信nonce准备后才允许写入' > "$OUT/预期内容-$ARCH.txt"
 cmp "$OUT/独立复读-$ARCH.txt" "$OUT/预期内容-$ARCH.txt"
done
printf '同步能力普通文件回归通过：%s\n' "$OUT"
