#!/bin/bash
# 只验证生产策略与普通文件句柄，不创建映像、不枚举或修改磁盘。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/core-tests
SWIFT_ARGS=(-target arm64-apple-macos26.0 -swift-version 6)
HELPER_ARGS=(-import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift
  Sources/App/Services/MountedFileSystemReader.swift
  Sources/PrivilegedHelper/HelperMedia.swift Sources/PrivilegedHelper/HelperNamespace.swift
  Sources/PrivilegedHelper/HelperEject.swift Sources/PrivilegedHelper/PrivilegedMountService.swift)
xcrun swiftc "${SWIFT_ARGS[@]}" Sources/Core/VolumeRecord.swift Tests/Core/EjectCapabilityTests.swift -o build/core-tests/弹出能力验证
build/core-tests/弹出能力验证
xcrun swiftc "${SWIFT_ARGS[@]}" Sources/Core/VolumeRecord.swift Tests/Core/VolumeRecordTests.swift -o build/core-tests/卷记录验证
build/core-tests/卷记录验证
xcrun swiftc "${SWIFT_ARGS[@]}" "${HELPER_ARGS[@]}" Tests/Core/PrivilegedHelperEjectTests.swift -o build/core-tests/管理员弹出策略验证
build/core-tests/管理员弹出策略验证
xcrun swiftc "${SWIFT_ARGS[@]}" "${HELPER_ARGS[@]}" Tests/Core/PrivilegedHelperHandleTests.swift -o build/core-tests/句柄传输回归
build/core-tests/句柄传输回归
