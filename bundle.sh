#!/bin/bash
set -euo pipefail

# Build a macOS .app bundle from the SPM executable.
# Usage: ./bundle.sh [--release]
#
# Output: build/VoiceEditor.app

APP_NAME="VoiceEditor"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"

# Parse args
CONFIG="debug"
SWIFT_CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    SWIFT_CONFIG="release"
    echo "==> Building in RELEASE mode..."
else
    echo "==> Building in DEBUG mode..."
fi

# Step 1: Build
swift build -c "$SWIFT_CONFIG"

# Step 2: Create bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"

# Step 3: Copy binary
cp ".build/$CONFIG/$APP_NAME" "$MACOS/$APP_NAME"

# Step 4: Copy Info.plist
cp "$APP_NAME/Info.plist" "$CONTENTS/Info.plist"

# Step 4b: Copy Resources
mkdir -p "$CONTENTS/Resources"
cp "ACKNOWLEDGMENTS.md" "$CONTENTS/Resources/ACKNOWLEDGMENTS.md"

# Step 5: Sign the bundle
# Note: com.apple.developer.kernel.increased-memory-limit requires a paid
# Apple Developer ID certificate. For ad-hoc distribution we create a
# stripped entitlements file that omits restricted entitlements.
ENTITLEMENTS="$APP_NAME/$APP_NAME.entitlements"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"  # Use env var or ad-hoc

if [ "$SIGN_IDENTITY" != "-" ] && [ -f "$ENTITLEMENTS" ]; then
    echo "==> Signing with Developer ID + full entitlements..."
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
    # Ad-hoc: strip restricted entitlements that require provisioning
    ADHOC_ENT=$(mktemp)
    cat > "$ADHOC_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
PLIST
    echo "==> Signing ad-hoc (restricted entitlements stripped)..."
    codesign --force --sign - --entitlements "$ADHOC_ENT" "$APP_BUNDLE"
    rm -f "$ADHOC_ENT"
fi

# Step 6: Notarize (only when signed with Developer ID)
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Notarizing..."
    ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    TEAM_ID="${NOTARIZE_TEAM_ID:-R4S8W6UC7K}"
    APPLE_ID="${NOTARIZE_APPLE_ID:-}"
    KEYCHAIN_PROFILE="${NOTARIZE_KEYCHAIN_PROFILE:-}"

    if [ -n "$KEYCHAIN_PROFILE" ]; then
        xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    elif [ -n "$APPLE_ID" ]; then
        echo "Enter app-specific password for notarization:"
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --wait
    else
        echo "WARNING: Skipping notarization — set NOTARIZE_KEYCHAIN_PROFILE or NOTARIZE_APPLE_ID"
        echo "  To set up:  xcrun notarytool store-credentials \"HitokuDraft\" --apple-id you@example.com --team-id $TEAM_ID"
        echo "  Then run:   NOTARIZE_KEYCHAIN_PROFILE=HitokuDraft ./bundle.sh --release"
        rm -f "$ZIP_PATH"
    fi

    if [ -f "$ZIP_PATH" ]; then
        echo "==> Stapling notarization ticket..."
        xcrun stapler staple "$APP_BUNDLE"
        rm -f "$ZIP_PATH"
        echo "==> Notarization complete — app is ready for distribution."
    fi
else
    # Ad-hoc: clear quarantine so the app opens without Gatekeeper prompts
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "==> Built: $APP_BUNDLE"
echo "    Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
echo "To run:  open $APP_BUNDLE"
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "To ship: zip -r $APP_NAME.zip $APP_BUNDLE"
    echo "         (notarized — no Gatekeeper warning on receiving Mac)"
else
    echo "To ship: zip -r $APP_NAME.zip $APP_BUNDLE"
    echo ""
    echo "Tip: On the receiving Mac, run: xattr -cr $APP_NAME.app"
    echo "     (clears Gatekeeper quarantine for unsigned apps)"
fi
