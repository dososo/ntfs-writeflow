#!/bin/bash
# 只验证生产策略与普通文件句柄，不创建映像、不枚举或修改磁盘。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
TEST_ARCH="${NTFS_TEST_ARCH:-$(uname -m)}"
case "$TEST_ARCH" in
  arm64|x86_64) ;;
  *) echo '测试架构仅支持 arm64 或 x86_64。' >&2; exit 2 ;;
esac
OUT="build/core-tests/$TEST_ARCH"
mkdir -p "$OUT" build/helper-candidate
RUN=(arch "-$TEST_ARCH")
SWIFT_ARGS=(-target "$TEST_ARCH-apple-macos13.0" -swift-version 6 -warnings-as-errors
  -Xlinker -weak_framework -Xlinker FSKit)
HELPER_ARGS=(-import-objc-header Sources/PrivilegedHelper/Helper-Bridging-Header.h
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift
  Sources/App/Services/MountedFileSystemReader.swift
  Sources/PrivilegedHelper/HelperMedia.swift Sources/PrivilegedHelper/HelperNamespace.swift
  Sources/PrivilegedHelper/HelperEject.swift Sources/PrivilegedHelper/ManagedUnmount.swift
  Sources/PrivilegedHelper/LegacyMountProcess.swift Sources/PrivilegedHelper/PrivilegedMountService.swift)
xcrun swiftc "${SWIFT_ARGS[@]}" Sources/Core/VolumeRecord.swift Tests/Core/EjectCapabilityTests.swift -o "$OUT/弹出能力验证"
"${RUN[@]}" "$OUT/弹出能力验证"
xcrun swiftc "${SWIFT_ARGS[@]}" Sources/Core/VolumeRecord.swift Tests/Core/VolumeRecordTests.swift -o "$OUT/卷记录验证"
"${RUN[@]}" "$OUT/卷记录验证"
xcrun swiftc "${SWIFT_ARGS[@]}" "${HELPER_ARGS[@]}" Tests/Core/PrivilegedHelperEjectTests.swift -o "$OUT/管理员弹出策略验证"
"${RUN[@]}" "$OUT/管理员弹出策略验证"
xcrun swiftc "${SWIFT_ARGS[@]}" "${HELPER_ARGS[@]}" Tests/Core/PrivilegedHelperHandleTests.swift -o "$OUT/句柄传输回归"
"${RUN[@]}" "$OUT/句柄传输回归"

# 同一真实助手模块覆盖发现、正常卸载、兼容收尾与安全策略。
for test in ManagedMountDiscovery ManagedUnmount LegacyMountEnvironment LegacyMountProcess PrivilegedHelperPolicy PrivilegedHelperACL PrivilegedHelperSession; do
  xcrun swiftc "${SWIFT_ARGS[@]}" "${HELPER_ARGS[@]}" "Tests/Core/${test}Tests.swift" -o "$OUT/$test"
  "${RUN[@]}" "$OUT/$test"
done
xcrun swiftc "${SWIFT_ARGS[@]}" Sources/Core/VolumeRecord.swift Tests/Core/MountStateTests.swift -o "$OUT/挂载状态验证"
"${RUN[@]}" "$OUT/挂载状态验证"
xcrun swiftc "${SWIFT_ARGS[@]}" -import-objc-header Configuration/App-Bridging-Header.h \
  Sources/Core/VolumeRecord.swift Sources/HelperShared/*.swift \
  Sources/App/Services/PrivilegedMountClient.swift Sources/App/Services/AuthorizedDeviceHandle.swift \
  Sources/App/Services/DiskService.swift Sources/App/Services/RetainedDiskBinding.swift \
  Sources/App/Services/MountedFileSystemReader.swift Tests/Core/UnmountSequenceTests.swift -o "$OUT/卸载序列验证"
"${RUN[@]}" "$OUT/卸载序列验证"
