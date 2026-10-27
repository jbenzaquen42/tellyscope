#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE_NAME="${1:-iPhone 17 Pro}"
DERIVED_DATA="${TMPDIR:-/tmp}/TVADB-Simulator-DerivedData"
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "错误：未找到可用的完整 Xcode。" >&2
  exit 1
fi
"$PROJECT_ROOT/scripts/prepare-adb-prebuilt.sh" iphonesimulator arm64
DEVICE_ID="$(xcrun simctl list devices available | sed -n "s/^[[:space:]]*$DEVICE_NAME (\([A-F0-9-]*\)) (.*/\1/p" | head -n 1)"
if [[ -z "$DEVICE_ID" ]]; then
  echo "错误：没有找到模拟器：$DEVICE_NAME" >&2
  echo "可用设备：" >&2
  xcrun simctl list devices available >&2
  exit 1
fi
xcodebuild \
  -project "$PROJECT_ROOT/iosadb.xcodeproj" \
  -scheme TVADB \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  build
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/TVADB.app"
xcrun simctl launch "$DEVICE_ID" com.tvadb.ios
open -a Simulator
echo "TVADB 已运行在 ${DEVICE_NAME}。"
