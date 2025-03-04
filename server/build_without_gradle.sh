#!/usr/bin/env bash
#
# This script generates the scrcpy binary "manually" (without gradle).
#
# Adapt Android platform and build tools versions (via ANDROID_PLATFORM and
# ANDROID_BUILD_TOOLS environment variables).
#
# Then execute:
#
#     BUILD_DIR=my_build_dir ./build_without_gradle.sh

set -e

SCRCPY_DEBUG=false
SCRCPY_VERSION_NAME=1.24

SERVER_DIR="$(realpath $(dirname "$0"))"
KEYSTORE_PROPERTIES_FILE="$SERVER_DIR/keystore.properties"

if [[ ! -f "$KEYSTORE_PROPERTIES_FILE" ]]
then
    echo "The file '$KEYSTORE_PROPERTIES_FILE' does not exist." >&2
    echo "Please read '$SERVER_DIR/HOWTO_keystore.txt'." >&2
    exit 1
fi

declare -A props
while IFS='=' read -r key value
do
    props["$key"]="$value"
done < "$KEYSTORE_PROPERTIES_FILE"

KEYSTORE_FILE=${props['storeFile']}
KEYSTORE_PASSWORD=${props['storePassword']}
KEYSTORE_KEY_ALIAS=${props['keyAlias']}
KEYSTORE_KEY_PASSWORD=${props['keyPassword']}

if [[ ! -f "$KEYSTORE_FILE" ]]
then
    echo "Keystore '$KEYSTORE_FILE' (read from '$KEYSTORE_PROPERTIES_FILE')" \
         "does not exist." >&2
    echo "Please read '$SERVER_DIR/HOWTO_keystore.txt'." >&2
    exit 2
fi

PLATFORM=${ANDROID_PLATFORM:-33}
BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-33.0.0}
BUILD_TOOLS_DIR="$ANDROID_HOME/build-tools/$BUILD_TOOLS"

BUILD_DIR="$(realpath ${BUILD_DIR:-build_manual})"
CLASSES_DIR="$BUILD_DIR/classes"
SERVER_BINARY=scrcpy-server.apk
ANDROID_JAR="$ANDROID_HOME/platforms/android-$PLATFORM/android.jar"

echo "Platform: android-$PLATFORM"
echo "Build-tools: $BUILD_TOOLS"
echo "Build dir: $BUILD_DIR"

rm -rf "$CLASSES_DIR" "$BUILD_DIR/$SERVER_BINARY" classes.dex
mkdir -p "$CLASSES_DIR/com/genymobile/scrcpy"

<< EOF cat > "$CLASSES_DIR/com/genymobile/scrcpy/BuildConfig.java"
package com.genymobile.scrcpy;

public final class BuildConfig {
  public static final boolean DEBUG = $SCRCPY_DEBUG;
  public static final String VERSION_NAME = "$SCRCPY_VERSION_NAME";
}
EOF

echo "Generating java from aidl..."
cd "$SERVER_DIR/src/main/aidl"
"$BUILD_TOOLS_DIR/aidl" -o"$CLASSES_DIR" android/view/IRotationWatcher.aidl
"$BUILD_TOOLS_DIR/aidl" -o"$CLASSES_DIR" \
    android/content/IOnPrimaryClipChangedListener.aidl

echo "Compiling java sources..."
cd ../java
javac -bootclasspath "$ANDROID_JAR" -cp "$CLASSES_DIR" -d "$CLASSES_DIR" \
    -source 1.8 -target 1.8 \
    com/genymobile/scrcpy/*.java \
    com/genymobile/scrcpy/wrappers/*.java

echo "Dexing..."
cd "$CLASSES_DIR"

if [[ $PLATFORM -lt 31 ]]
then
    # use dx
    "$BUILD_TOOLS_DIR/dx" --dex --output "$BUILD_DIR/classes.dex" \
        android/view/*.class \
        android/content/*.class \
        com/genymobile/scrcpy/*.class \
        com/genymobile/scrcpy/wrappers/*.class
    cd "$BUILD_DIR"
else
    # use d8
    "$BUILD_TOOLS_DIR/d8" --classpath "$ANDROID_JAR" \
        --output "$BUILD_DIR/classes.zip" \
        android/view/*.class \
        android/content/*.class \
        com/genymobile/scrcpy/*.class \
        com/genymobile/scrcpy/wrappers/*.class

    cd "$BUILD_DIR"
    unzip -o classes.zip classes.dex  # we need the inner classes.dex
fi

echo "Packaging..."
# note: if a res directory exists, add: -S "$SERVER_DIR/src/main/res"
"$BUILD_TOOLS_DIR/aapt" package -f \
    -M "$SERVER_DIR/src/main/AndroidManifest.xml" \
    -I "$ANDROID_JAR" \
    -F "$SERVER_BINARY.unaligned"
"$BUILD_TOOLS_DIR/aapt" add "$SERVER_BINARY.unaligned" classes.dex
"$BUILD_TOOLS_DIR/zipalign" -p 4 "$SERVER_BINARY.unaligned" "$SERVER_BINARY"
rm "$SERVER_BINARY.unaligned"

"$BUILD_TOOLS_DIR/apksigner" sign \
    --ks "$KEYSTORE_FILE" \
    --ks-pass "pass:$KEYSTORE_PASSWORD" \
    --ks-key-alias "$KEYSTORE_KEY_ALIAS" \
    --key-pass "pass:$KEYSTORE_KEY_PASSWORD" \
    "$SERVER_BINARY"

echo "Server generated in $BUILD_DIR/$SERVER_BINARY"
