#!/bin/bash
# 策略使用独立默认值域；原生监控仅观察系统元数据，不挂载、卸载或写入设备。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/core-tests
SWIFT=(xcrun swiftc -target arm64-apple-macos26.0 -swift-version 6 -warnings-as-errors)
"${SWIFT[@]}" Sources/Core/VolumeRecord.swift Sources/Core/AutoMountPolicy.swift \
  Sources/App/Services/AutoMountCoordinator.swift Tests/Core/AutoMountPolicyTests.swift \
  -o build/core-tests/自动挂载策略验证
build/core-tests/自动挂载策略验证
"${SWIFT[@]}" Sources/App/Services/AutoMountEnvironment.swift Tests/Core/AutoMountEnvironmentTests.swift \
  -o build/core-tests/自动挂载环境验证
build/core-tests/自动挂载环境验证
"${SWIFT[@]}" Sources/App/Services/AutoMountEnvironment.swift Sources/App/Services/DiskEventMonitor.swift \
  Tests/Core/DiskEventMonitorTests.swift -o build/core-tests/原生事件策略验证
build/core-tests/原生事件策略验证
"${SWIFT[@]}" Sources/App/Services/LoginLaunchService.swift Tests/Core/LoginLaunchTests.swift \
  -o build/core-tests/登录启动验证
build/core-tests/登录启动验证
"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelAutoMountTests.swift \
  -o build/core-tests/自动挂载模型验证
build/core-tests/自动挂载模型验证

"${SWIFT[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/*.swift Sources/HelperShared/*.swift Sources/App/Services/*.swift \
  Sources/App/AppModel*.swift Tests/Core/AppModelDisappearanceTests.swift \
  -o build/core-tests/消失卷列表验证
build/core-tests/消失卷列表验证
