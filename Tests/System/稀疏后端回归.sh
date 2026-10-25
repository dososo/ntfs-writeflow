#!/bin/bash
# 仅新建普通文件镜像，不挂载或注册扩展；失败样本也保留。
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p Tests/System/结果
OUT="$(mktemp -d Tests/System/结果/稀疏后端.XXXXXX)"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -DHAVE_CONFIG_H=1 \
  -I build/engine/arm64 -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
  -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge.o"
xcrun clang -arch arm64 -fobjc-arc -fmodules -mmacosx-version-min=26.0 \
  -I ThirdParty/NTFSBridge -c ThirdParty/FSKitAdapter/ntfs_device_fskit.m -o "$OUT/backend.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -I ThirdParty/NTFSBridge \
  Tests/System/稀疏后端回归.c "$OUT/bridge.o" "$OUT/backend.o" \
  build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a \
  -framework Foundation -framework FSKit -framework CoreFoundation -o "$OUT/稀疏后端回归"
python3 -c 'import sys; f=open(sys.argv[1],"xb"); f.truncate(256*1024*1024); f.close()' "$OUT/镜像.img"
build/engine/arm64/ntfsprogs/mkntfs -F -Q -L SparseTest "$OUT/镜像.img" > "$OUT/格式化.txt" 2>&1
"$OUT/稀疏后端回归" "$OUT/镜像.img" | tee "$OUT/结果.txt"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -DHAVE_CONFIG_H=1 \
  -Dntfs_attr_pwrite=regression_attr_pwrite -Dntfs_attr_truncate=regression_attr_truncate \
  -I build/engine/arm64 -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
  -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/错误桥.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -DHAVE_CONFIG_H=1 \
  -I build/engine/arm64 -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge \
  Tests/System/稀疏写入错误回归.c "$OUT/错误桥.o" "$OUT/backend.o" \
  build/engine/arm64/libntfs-3g/.libs/libntfs-3g.a \
  -framework Foundation -framework FSKit -framework CoreFoundation -o "$OUT/稀疏写入错误回归"
python3 -c 'import sys; f=open(sys.argv[1],"xb"); f.truncate(64*1024*1024); f.close()' "$OUT/错误镜像.img"
build/engine/arm64/ntfsprogs/mkntfs -F -Q -L SparseFault "$OUT/错误镜像.img" > "$OUT/错误格式化.txt" 2>&1
"$OUT/稀疏写入错误回归" "$OUT/错误镜像.img" | tee "$OUT/错误结果.txt"
printf '证据目录：%s\n' "$OUT"
