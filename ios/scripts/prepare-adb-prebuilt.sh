#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_NAME="${1:-}"
ARCH_NAME="${2:-arm64}"
case "$PLATFORM_NAME" in
  iphoneos|iphonesimulator)
    ;;
  *)
    echo "错误：不支持的 ADB 目标平台：${PLATFORM_NAME:-未指定}" >&2
    exit 1
    ;;
esac
if [[ "$ARCH_NAME" != "arm64" ]]; then
  echo "错误：仓库当前只提供 arm64 ADB 预编译库：$PLATFORM_NAME/$ARCH_NAME" >&2
  exit 1
fi
ARCHIVE="$PROJECT_ROOT/Vendor/adb-prebuilt/libadb-full-${PLATFORM_NAME}-${ARCH_NAME}.zip"
OUTPUT_DIR="$PROJECT_ROOT/Vendor/adb-mobile/output/${PLATFORM_NAME}/${ARCH_NAME}"
OUTPUT_LIBRARY="$OUTPUT_DIR/libadb-full.a"
case "$PLATFORM_NAME" in
  iphoneos) EXPECTED_SHA256=addee382f85a4a40b3af4f10c2b5f4ce65082a7114f896bd72ba25e70f1ef247 ;;
  iphonesimulator) EXPECTED_SHA256=0e809d784c5354c700d7151ee538281812b9de912b8550efd1ca1f0f07901f90 ;;
esac
if [[ ! -f "$ARCHIVE" ]]; then
  echo "错误：缺少 ADB 预编译库：$ARCHIVE" >&2
  exit 1
fi
ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "错误：ADB 预编译库 SHA-256 不匹配：$ARCHIVE" >&2
  exit 1
fi
if [[ -f "$OUTPUT_LIBRARY" && "$OUTPUT_LIBRARY" -nt "$ARCHIVE" ]]; then
  exit 0
fi
mkdir -p "$OUTPUT_DIR"
/usr/bin/unzip -oq "$ARCHIVE" -d "$OUTPUT_DIR"
if [[ ! -f "$OUTPUT_LIBRARY" ]]; then
  echo "错误：ADB 预编译库解压失败：$OUTPUT_LIBRARY" >&2
  exit 1
fi
touch "$OUTPUT_LIBRARY"
echo "已准备 ADB 静态库：$OUTPUT_LIBRARY"
