#!/bin/bash
# 只复制包内配置，不注册系统服务。
set -euo pipefail
DESTINATION="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons"
mkdir -p "$DESTINATION"
cp "$SRCROOT/Configuration/com.blteam.ntfsworkbench.mount-helper.plist" "$DESTINATION/"
