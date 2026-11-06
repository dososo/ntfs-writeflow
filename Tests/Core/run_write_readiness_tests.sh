#!/bin/bash
# 仅编译并调用纯协议、内存卷记录与映射，不枚举设备、不连接XPC、不挂载。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
for TEST_ARCH in arm64 x86_64; do
  OUT="build/readiness-tests/$TEST_ARCH"
  mkdir -p "$OUT"
  xcrun swiftc -target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors \
    -Xlinker -weak_framework -Xlinker FSKit -import-objc-header Configuration/App-Bridging-Header.h \
    Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
    Sources/App/AppModel*.swift Tests/Core/FSKitWriteReadinessTests.swift -o "$OUT/准备状态回归"
  arch "-$TEST_ARCH" "$OUT/准备状态回归"
  xcrun swiftc -target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors \
    -Xlinker -weak_framework -Xlinker FSKit -import-objc-header Configuration/App-Bridging-Header.h \
    Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
    Sources/App/AppModel*.swift Tests/Core/FSKitReadinessRefreshTests.swift -o "$OUT/异步实例重核回归"
  arch "-$TEST_ARCH" "$OUT/异步实例重核回归"
  for TEST in VolumeRecord EjectCapability MountState; do
    xcrun swiftc -target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors \
      Sources/Core/VolumeRecord.swift "Tests/Core/${TEST}Tests.swift" -o "$OUT/$TEST"
    arch "-$TEST_ARCH" "$OUT/$TEST"
  done
  xcrun swiftc -typecheck -parse-as-library -target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors \
    -import-objc-header Configuration/App-Bridging-Header.h \
    Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift Sources/App/Views/*.swift Sources/App/*.swift
  printf '%s 应用与界面严格类型检查通过。\n' "$TEST_ARCH"
done
