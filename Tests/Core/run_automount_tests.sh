#!/bin/bash
# 策略使用独立默认值域；原生监控仅观察系统元数据，不挂载、卸载或写入设备。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
TEST_ARCH="${NTFS_TEST_ARCH:-$(uname -m)}"
case "$TEST_ARCH" in
  arm64|x86_64) ;;
  *) echo '测试架构仅支持 arm64 或 x86_64。' >&2; exit 2 ;;
esac
OUT="build/core-tests/$TEST_ARCH"
mkdir -p "$OUT"
RUN=(arch "-$TEST_ARCH")
SWIFT=(xcrun swiftc -target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors
  -Xlinker -weak_framework -Xlinker FSKit)
"${SWIFT[@]}" Sources/Core/VolumeRecord.swift Sources/Core/AutoMountPolicy.swift \
  Sources/App/Services/AutoMountCoordinator.swift Tests/Core/AutoMountPolicyTests.swift \
  -o "$OUT/自动挂载策略验证"
"${RUN[@]}" "$OUT/自动挂载策略验证"
"${SWIFT[@]}" Sources/App/Services/AutoMountEnvironment.swift Tests/Core/AutoMountEnvironmentTests.swift \
  -o "$OUT/自动挂载环境验证"
"${RUN[@]}" "$OUT/自动挂载环境验证"
"${SWIFT[@]}" Sources/App/Services/AutoMountEnvironment.swift Sources/App/Services/DiskEventMonitor.swift \
  Tests/Core/DiskEventMonitorTests.swift -o "$OUT/原生事件策略验证"
"${RUN[@]}" "$OUT/原生事件策略验证"
"${SWIFT[@]}" Sources/App/Services/LoginLaunchService.swift Tests/Core/LoginLaunchTests.swift \
  -o "$OUT/登录启动验证"
"${RUN[@]}" "$OUT/登录启动验证"
"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelAutoMountTests.swift \
  -o "$OUT/自动挂载模型验证"
"${RUN[@]}" "$OUT/自动挂载模型验证"

"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelDisappearanceTests.swift \
  -o "$OUT/消失卷列表验证"
"${RUN[@]}" "$OUT/消失卷列表验证"

"${SWIFT[@]}" Sources/Core/AutoMountSessionState.swift Tests/Core/AutoMountSessionStateTests.swift \
  -o "$OUT/会话状态验证"
"${RUN[@]}" "$OUT/会话状态验证"
"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelLoginRevocationTests.swift \
  -o "$OUT/登录撤销验证"
"${RUN[@]}" "$OUT/登录撤销验证"

"${SWIFT[@]}" Sources/Core/AutoMountSessionState.swift Tests/Core/AutoMountSessionTransitionTests.swift \
  -o "$OUT/会话组合验证"
"${RUN[@]}" "$OUT/会话组合验证"
"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelSessionNotificationTests.swift \
  -o "$OUT/会话通知接线验证"
"${RUN[@]}" "$OUT/会话通知接线验证"

"${SWIFT[@]}" Sources/Core/SessionVerificationRequest.swift Tests/Core/SessionVerificationRequestTests.swift \
  -o "$OUT/限时会话配置验证"
"${RUN[@]}" "$OUT/限时会话配置验证"
"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/SessionVerificationRecordTests.swift \
  -o "$OUT/限时会话日志验证"
"${RUN[@]}" "$OUT/限时会话日志验证"

"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelObservationTests.swift \
  -o "$OUT/模型状态发布验证"
"${RUN[@]}" "$OUT/模型状态发布验证"
