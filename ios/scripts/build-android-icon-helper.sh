#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_DIR="$PROJECT_DIR/android-helper/src"
OUTPUT_FILE="$PROJECT_DIR/iosadb/Resources/TVADBIconHelper.dex"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tvadb-icon-helper-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
: "${JAVA_HOME:?Set JAVA_HOME to a JDK 17 or newer installation}"
: "${ANDROID_JAR:?Set ANDROID_JAR to an Android platform android.jar}"
: "${R8_JAR:?Set R8_JAR to the Android R8/D8 compiler JAR}"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex"
"$JAVA_HOME/bin/javac" \
    -encoding UTF-8 \
    --release 8 \
    -classpath "$ANDROID_JAR" \
    -d "$BUILD_DIR/classes" \
    "$SOURCE_DIR/com/tvadb/helper/AppPresentationHelper.java" \
    "$SOURCE_DIR/com/tvadb/helper/MouseDisplayAssociation.java"
"$JAVA_HOME/bin/java" \
    -cp "$R8_JAR" \
    com.android.tools.r8.D8 \
    --release \
    --min-api 21 \
    --lib "$ANDROID_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/tvadb/helper/AppPresentationHelper.class" \
    "$BUILD_DIR/classes/com/tvadb/helper/MouseDisplayAssociation.class"
cp "$BUILD_DIR/dex/classes.dex" "$OUTPUT_FILE"
echo "Generated $OUTPUT_FILE"
