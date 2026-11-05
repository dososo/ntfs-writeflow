#!/usr/bin/env bash
# 只构建固定版本的开源引擎，不安装驱动，不访问设备。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/ThirdParty/ntfs-3g"
PIN="7f0f841fc52cf719106c5c93bafe465004e36816"
WORK="$ROOT/build/engine"
BUILD_ARCH="${NTFS_BUILD_ARCH:-arm64}"
case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *) printf 'NTFS_BUILD_ARCH 仅支持 arm64 或 x86_64。\n' >&2; exit 2 ;;
esac
BUILD="$WORK/$BUILD_ARCH"
CONFIGURE_ARCH=()
HOST_ARCH="$(uname -m)"
if [[ "$BUILD_ARCH" != "$HOST_ARCH" ]]; then
  CONFIGURE_ARCH=("--host=$BUILD_ARCH-apple-darwin" "--build=$HOST_ARCH-apple-darwin")
fi
if [[ "$(git -C "$SOURCE" rev-parse --is-inside-work-tree 2>/dev/null || true)" != true ]]; then
  printf '缺少固定版本源码：%s\n' "$SOURCE" >&2
  exit 1
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { printf '引擎提交与锁定版本不符。\n' >&2; exit 1; }
git -C "$SOURCE" diff --quiet
git -C "$SOURCE" diff --cached --quiet
mkdir -p "$WORK/source" "$BUILD"
if [[ ! -f "$WORK/source/configure" ]]; then
  git -C "$SOURCE" archive "$PIN" | tar -xf - -C "$WORK/source"
  cp "$ROOT/ThirdParty/NTFSBridge/libgcrypt.m4" "$WORK/source/m4/libgcrypt.m4"
  (cd "$WORK/source"; glibtoolize --force --copy --install; LIBTOOLIZE=glibtoolize autoreconf -fi -I m4)
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [[ ! -f "$BUILD/Makefile" ]]; then
  (cd "$BUILD"; CC=clang CFLAGS="-arch $BUILD_ARCH -isysroot $SDK -mmacosx-version-min=15.4 -O2" \
    ../source/configure ${CONFIGURE_ARCH[@]+"${CONFIGURE_ARCH[@]}"} --disable-shared --enable-static --disable-ntfs-3g \
    --enable-ntfsprogs --disable-crypto --disable-nls)
fi
make -C "$BUILD/libntfs-3g" -j4
make -C "$BUILD/ntfsprogs" -j4 mkntfs ntfscat ntfsls ntfsinfo
printf '引擎与离线工具构建完成：%s\n' "$BUILD"
