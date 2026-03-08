#!/bin/bash
set -e

APP_NAME="VoiceEditor"
BUILD_CONFIG="${1:-debug}"
BUILD_DIR=".build/$BUILD_CONFIG"
APP_BUNDLE="$APP_NAME.app"

echo "Building $APP_NAME ($BUILD_CONFIG)..."
swift build -c "$BUILD_CONFIG"

# Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$APP_NAME/Info.plist" "$APP_BUNDLE/Contents/"

# PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign with entitlements
codesign --force --sign - \
    --entitlements "$APP_NAME/$APP_NAME.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "Built $APP_BUNDLE ($BUILD_CONFIG)"
echo "Run with: open $APP_BUNDLE"
