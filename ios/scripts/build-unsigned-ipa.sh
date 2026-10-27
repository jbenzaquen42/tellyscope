#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/dist"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tvadb-build.XXXXXX")"

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未安装 Xcode。请先从 App Store 安装完整 Xcode。" >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "错误：当前只启用了 Command Line Tools。" >&2
  echo "安装 Xcode 后执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

bash "$PROJECT_ROOT/scripts/prepare-adb-prebuilt.sh" iphoneos arm64

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT/Payload"

xcodebuild \
  -quiet \
  -project "$PROJECT_ROOT/iosadb.xcodeproj" \
  -scheme TVADB \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_PATH="$BUILD_ROOT/DerivedData/Build/Products/Release-iphoneos/TVADB.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "错误：构建成功但未找到 TVADB.app" >&2
  exit 1
fi

cp -R "$APP_PATH" "$BUILD_ROOT/Payload/TVADB.app"
IPA_PATH="$OUTPUT_DIR/TVADB-unsigned.ipa"
/bin/rm -f "$IPA_PATH"
(
  cd "$BUILD_ROOT"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

echo "已生成：$IPA_PATH"
python3 "$PROJECT_ROOT/scripts/verify-unsigned-ipa.py" "$IPA_PATH"
