#!/bin/bash
# 构建可选macFUSE前端；不安装运行时、不挂载卷，固定引擎只在本地副本配置。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCH="${1:-${NTFS_BUILD_ARCH:-arm64}}"
case "$ARCH" in arm64|x86_64) ;; *) echo '兼容后端架构仅支持arm64或x86_64。' >&2; exit 2;; esac
PIN=7f0f841fc52cf719106c5c93bafe465004e36816
[[ "$(git -C ThirdParty/ntfs-3g rev-parse HEAD)" == "$PIN" ]] || { echo '固定引擎版本不符。' >&2; exit 1; }
git -C ThirdParty/ntfs-3g diff --quiet
git -C ThirdParty/ntfs-3g diff --cached --quiet
python3 - <<'PY'
import hashlib,json
from pathlib import Path
for name,digest in json.loads(Path('Tests/Compatibility/macfuse_header_pins.json').read_text()).items():
    if hashlib.sha256((Path('ThirdParty/MacFUSEHeaders')/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('固定macFUSE头文件或许可校验失败：'+name)
PY
BASE="$ROOT/build/legacy"
SOURCE="$BASE/source"
ENGINE="$BASE/engine-$ARCH-13"
OUT="$BASE/$ARCH"
mkdir -p "$SOURCE" "$ENGINE" "$OUT"
if [[ ! -f "$SOURCE/configure" ]]; then
  git -C ThirdParty/ntfs-3g archive --format=tar --output="$BASE/固定引擎源码.tar" "$PIN"
  tar -xf "$BASE/固定引擎源码.tar" -C "$SOURCE"
  cp ThirdParty/NTFSBridge/libgcrypt.m4 "$SOURCE/m4/libgcrypt.m4"
  (cd "$SOURCE"; glibtoolize --force --copy --install; LIBTOOLIZE=glibtoolize autoreconf -fi -I m4)
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
HOST="$(uname -m)"
CONFIGURE_ARCH=()
if [[ "$ARCH" != "$HOST" ]]; then CONFIGURE_ARCH=("--host=$ARCH-apple-darwin" "--build=$HOST-apple-darwin"); fi
if [[ ! -f "$ENGINE/Makefile" ]]; then
  (cd "$ENGINE"; CC=clang CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=13.0 -O2" \
    ../source/configure ${CONFIGURE_ARCH[@]+"${CONFIGURE_ARCH[@]}"} --disable-shared --enable-static --disable-ntfs-3g \
    --enable-ntfsprogs --disable-crypto --disable-nls)
fi
make -C "$ENGINE/libntfs-3g" -j4
COMMON=(-arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min=13.0 -O2 -D_FILE_OFFSET_BITS=64 -DHAVE_CONFIG_H=1
  -I "$ENGINE" -I ThirdParty/ntfs-3g/include -I ThirdParty/NTFSBridge -I ThirdParty/MacFUSEHeaders -I Sources/LegacyBackend)
xcrun clang "${COMMON[@]}" -c ThirdParty/NTFSBridge/ntfs_fskit.c -o "$OUT/bridge.o"
for NAME in legacy_device legacy_volume legacy_lease legacy_options legacy_main; do
  xcrun clang "${COMMON[@]}" -Wall -Wextra -Werror -c "Sources/LegacyBackend/$NAME.c" -o "$OUT/$NAME.o"
done
xcrun clang -arch "$ARCH" -mmacosx-version-min=13.0 "$OUT/legacy_main.o" "$OUT/legacy_device.o" "$OUT/legacy_volume.o" "$OUT/legacy_lease.o" "$OUT/legacy_options.o" \
  "$OUT/bridge.o" "$ENGINE/libntfs-3g/.libs/libntfs-3g.a" -framework CoreFoundation -o "$OUT/NTFSWriteFlowLegacy"
echo "兼容前端构建完成：$OUT/NTFSWriteFlowLegacy；运行仍需用户安装并启用macFUSE。"
