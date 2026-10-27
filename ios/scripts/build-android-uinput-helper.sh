#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_FILE="$PROJECT_DIR/android-uinput-helper/tvadb_virtual_mouse.c"
OUTPUT_DIR="$PROJECT_DIR/iosadb/Resources/AndroidUInput"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tvadb-uinput-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
CLANG_BIN=${CLANG_BIN:-$(xcrun --find clang)}
if [ -n "${LLD_BIN:-}" ]; then
    LINKER_BIN=$LLD_BIN
elif [ -x /opt/homebrew/opt/lld/bin/ld.lld ]; then
    LINKER_BIN=/opt/homebrew/opt/lld/bin/ld.lld
elif command -v ld.lld >/dev/null 2>&1; then
    LINKER_BIN=$(command -v ld.lld)
else
    echo "ld.lld is required. Install it with: brew install lld" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"
build_one() {
    name=$1
    target=$2
    minimum_api=$3
    extra_flag=${4:-}
    object_file="$BUILD_DIR/$name.o"
    output_file="$OUTPUT_DIR/TVADBVirtualMouse-$name.bin"
    "$CLANG_BIN" \
        -target "$target$minimum_api" \
        -Oz \
        -ffreestanding \
        -fno-builtin \
        -fno-stack-protector \
        -fno-unwind-tables \
        -fno-asynchronous-unwind-tables \
        -fomit-frame-pointer \
        -nostdlib \
        $extra_flag \
        -c "$SOURCE_FILE" \
        -o "$object_file"
    "$LINKER_BIN" \
        --entry=_start \
        --strip-all \
        -static \
        -z max-page-size=4096 \
        -o "$output_file" \
        "$object_file"
    chmod 644 "$output_file"
    echo "Generated $output_file"
}
build_one arm64 aarch64-linux-android 21
build_one armv7 armv7a-linux-androideabi 21 -marm
build_one x86 i686-linux-android 21
build_one x86_64 x86_64-linux-android 21
