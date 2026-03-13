#!/bin/bash
set -euo pipefail

# release.sh — Full release pipeline for Hitoku Draft
#
# Usage:
#   ./release.sh                    # interactive — prompts for version
#   ./release.sh 1.2.0              # non-interactive — uses provided version
#   ./release.sh 1.2.0 --dry-run   # show what would happen without executing
#   ./release.sh --resume           # resume after a failed push/build (uses version already in project.yml)
#
# Prerequisites (one-time setup — see DISTRIBUTION.md §7):
#   1. Developer ID certificate installed in Keychain
#   2. xcrun notarytool store-credentials "HitokuDraft" --apple-id ... --team-id R4S8W6UC7K
#   3. brew install create-dmg
#   4. npx wrangler available (for R2 upload: npm install -g wrangler && wrangler login)
#   5. Sparkle's generate_appcast available (built with SPM)
#
# What this script does:
#   1. Validates prerequisites
#   2. Bumps version in project.yml + regenerates Xcode project
#   3. xcodebuild archive → export (Developer ID) → notarize → staple
#   4. Creates DMG with create-dmg
#   5. Generates appcast.xml with Sparkle's generate_appcast
#   6. Uploads DMG to Cloudflare R2 (downloads.hitoku.me)
#   7. Deploys appcast.xml to hitoku.me via git push
#   8. Creates git tag and pushes to origin
#   9. Prints remaining manual step (update Gumroad product file)
#
# Hosting layout:
#   R2 bucket (hitokudraft):
#     hitokudraft/HitokuDraft-1.0.0+abc123.dmg   ← DMG downloads
#   Cloudflare Pages (hitoku.me):
#     apps/hitokudraft/appcast.xml                ← Sparkle checks this

SCHEME="HitokuDraft"
XCODE_PROJECT="HitokuDraft.xcodeproj"
DISPLAY_NAME="Hitoku Draft"
APP_SLUG="hitokudraft"                       # subdirectory under apps/ on hitoku.me
BUILD_DIR="build"
DIST_DIR="dist"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="ExportOptions.plist"
PROJECT_YML="project.yml"
WEBSITE_REPO="$HOME/Documents/business/hitokume"
R2_BUCKET="hitokudraft"                      # Cloudflare R2 bucket name
DMG_DOWNLOAD_BASE="https://downloads.hitoku.me/$APP_SLUG"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

# --- Parse arguments ---
DRY_RUN=false
RESUME=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --resume) RESUME=true ;;
        --help|-h)
            echo "Usage: ./release.sh [VERSION] [--dry-run]"
            echo "       ./release.sh --resume"
            echo ""
            echo "  VERSION    Semantic version (e.g., 1.2.0). Prompted if omitted."
            echo "  --dry-run  Show what would happen without executing."
            echo "  --resume   Resume a failed release (uses version already in project.yml)."
            exit 0
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$arg"
            else
                fail "Unknown argument: $arg"
            fi
            ;;
    esac
done

# --- Step 0: Validate prerequisites ---
info "Checking prerequisites..."

# Check project.yml exists
[[ -f "$PROJECT_YML" ]] || fail "Missing $PROJECT_YML — run from repo root"

# Check Xcode project exists
[[ -d "$XCODE_PROJECT" ]] || fail "Missing $XCODE_PROJECT — run xcodegen generate first"

# Check ExportOptions.plist
[[ -f "$EXPORT_OPTIONS" ]] || fail "Missing $EXPORT_OPTIONS"

# Check xcodegen
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found. Install with: brew install xcodegen"
ok "xcodegen available"

# Check Developer ID certificate
DETECTED_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [[ -n "$DETECTED_ID" ]]; then
    ok "Found signing identity: $DETECTED_ID"
else
    fail "No Developer ID certificate found. Install one from developer.apple.com."
fi

# Check notarization credentials
NOTARIZE_KEYCHAIN_PROFILE="${NOTARIZE_KEYCHAIN_PROFILE:-HitokuDraft}"

# Check create-dmg
command -v create-dmg >/dev/null 2>&1 || fail "create-dmg not found. Install with: brew install create-dmg"
ok "create-dmg available"

# Check website repo
if [[ -d "$WEBSITE_REPO/.git" ]]; then
    ok "Website repo found: $WEBSITE_REPO"
else
    fail "Website repo not found at $WEBSITE_REPO"
fi

# Check wrangler (needed for R2 upload)
if npx wrangler --version >/dev/null 2>&1; then
    ok "wrangler available"
else
    fail "wrangler not found. Install with: npm install -g wrangler && wrangler login"
fi

# Check for generate_appcast
GENERATE_APPCAST=""
if command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="generate_appcast"
else
    # Search in common SPM/Sparkle locations
    FOUND=$(find "${HOME}/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -1 || true)
    if [[ -z "$FOUND" ]]; then
        FOUND=$(find ".build" -name generate_appcast -type f 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$FOUND" ]]; then
        GENERATE_APPCAST="$FOUND"
        ok "Found generate_appcast: $GENERATE_APPCAST"
    else
        warn "generate_appcast not found. Appcast generation will be skipped."
        warn "  Build Sparkle from source or locate it in DerivedData."
    fi
fi

# --- Step 1: Determine version ---
CURRENT_MARKETING=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
info "Current version: $CURRENT_MARKETING (build $CURRENT_BUILD)"

if $RESUME; then
    # --- Resume mode: use version already in project.yml ---
    VERSION="$CURRENT_MARKETING"
    NEW_BUILD="$CURRENT_BUILD"

    if git tag -l "v$VERSION" | grep -q "v$VERSION"; then
        fail "Version v$VERSION already tagged — nothing to resume."
    fi

    info "Resuming release: v$VERSION (build $NEW_BUILD)"
    echo ""
    read -rp "Continue release v$VERSION from where it left off? [y/N] " CONFIRM
    if [[ "$CONFIRM" != [yY] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Push commit if not already on remote
    info "Pushing to origin..."
    git push origin main
    ok "Pushed to origin"
else
    # --- Normal mode: validate + bump + commit ---
    if [[ -z "$VERSION" ]]; then
        echo ""
        read -rp "Enter new version (e.g., 1.0.0): " VERSION
    fi

    # Validate semver format
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Invalid version format: $VERSION (expected X.Y.Z)"
    fi

    # Check for duplicate version
    if git tag -l "v$VERSION" | grep -q "v$VERSION"; then
        fail "Version v$VERSION already released (git tag exists). Use a new version number."
    fi
    if [[ "$VERSION" == "$CURRENT_MARKETING" ]]; then
        fail "Version $VERSION is already the current version in $PROJECT_YML. Bump to a new version."
    fi

    # --- Version jump sanity check ---
    # Parse current and new versions into components
    CUR_MAJOR="${CURRENT_MARKETING%%.*}"
    CUR_REST="${CURRENT_MARKETING#*.}"
    CUR_MINOR="${CUR_REST%%.*}"
    CUR_PATCH="${CUR_REST#*.}"

    NEW_MAJOR="${VERSION%%.*}"
    NEW_REST="${VERSION#*.}"
    NEW_MINOR="${NEW_REST%%.*}"
    NEW_PATCH="${NEW_REST#*.}"

    JUMP_WARN=""

    # Check for backwards version (without a higher component bumping)
    if (( NEW_MAJOR < CUR_MAJOR )); then
        JUMP_WARN="Major version goes backwards: $CURRENT_MARKETING → $VERSION"
    elif (( NEW_MAJOR == CUR_MAJOR && NEW_MINOR < CUR_MINOR )); then
        JUMP_WARN="Minor version goes backwards: $CURRENT_MARKETING → $VERSION"
    elif (( NEW_MAJOR == CUR_MAJOR && NEW_MINOR == CUR_MINOR && NEW_PATCH < CUR_PATCH )); then
        JUMP_WARN="Patch version goes backwards: $CURRENT_MARKETING → $VERSION"
    fi

    # Check for suspiciously large forward jumps
    if [[ -z "$JUMP_WARN" ]]; then
        if (( NEW_MAJOR - CUR_MAJOR >= 1 )); then
            JUMP_WARN="Major version jumps by $((NEW_MAJOR - CUR_MAJOR)): $CURRENT_MARKETING → $VERSION"
        elif (( NEW_MAJOR == CUR_MAJOR && NEW_MINOR - CUR_MINOR > 1 )); then
            JUMP_WARN="Minor version jumps by $((NEW_MINOR - CUR_MINOR)): $CURRENT_MARKETING → $VERSION"
        elif (( NEW_MAJOR == CUR_MAJOR && NEW_MINOR == CUR_MINOR && NEW_PATCH - CUR_PATCH > 3 )); then
            JUMP_WARN="Patch version jumps by $((NEW_PATCH - CUR_PATCH)): $CURRENT_MARKETING → $VERSION"
        fi
    fi

    if [[ -n "$JUMP_WARN" ]]; then
        echo ""
        warn "Unusual version jump detected: $JUMP_WARN"
        warn "Current: $CURRENT_MARKETING → New: $VERSION"
        read -rp "$(echo -e "${YELLOW}⚠${NC}") Is this intentional? [y/N] " JUMP_CONFIRM
        if [[ "$JUMP_CONFIRM" != [yY] ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    # Calculate build number (increment current)
    NEW_BUILD=$((CURRENT_BUILD + 1))

    info "Will release: v$VERSION (build $NEW_BUILD)"

    if $DRY_RUN; then
        echo ""
        info "[DRY RUN] Would perform the following:"
        echo "  1. Bump $PROJECT_YML → MARKETING_VERSION: \"$VERSION\", CURRENT_PROJECT_VERSION: \"$NEW_BUILD\""
        echo "  2. xcodegen generate (regenerate $XCODE_PROJECT)"
        echo "  2b. git add -A && git commit && git push origin main"
        echo "  3. xcodebuild archive -scheme $SCHEME → $ARCHIVE_PATH"
        echo "  4. Manual codesign (inside-out) → $EXPORT_PATH (Developer ID signing)"
        echo "  5. xcrun notarytool submit → Apple notarization"
        echo "  6. xcrun stapler staple → embed notarization ticket"
        echo "  7. Create DMG: HitokuDraft-$VERSION.dmg"
        echo "  8. Generate appcast.xml from DMG"
        echo "  9. Upload DMG to R2: $R2_BUCKET/$APP_SLUG/HitokuDraft-$VERSION+XXXX.dmg"
        echo "  10. Push appcast.xml → hitokume repo → Cloudflare Pages"
        echo "  11. Tag: git tag v$VERSION && git push origin v$VERSION"
        echo "  12. Only manual step: update Gumroad product file"
        exit 0
    fi

    # Confirm
    echo ""
    read -rp "Proceed with release v$VERSION? [y/N] " CONFIRM
    if [[ "$CONFIRM" != [yY] ]]; then
        echo "Aborted."
        exit 1
    fi

    # --- Step 2: Bump version + regenerate Xcode project ---
    info "Bumping version in $PROJECT_YML..."

    sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
    sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" "$PROJECT_YML"

    ok "Version bumped to $VERSION (build $NEW_BUILD)"

    info "Regenerating Xcode project..."
    xcodegen generate
    ok "Xcode project regenerated"

    # --- Step 2b: Commit all changes + push ---
    info "Committing all changes..."
    git add -A
    if git diff --cached --quiet; then
        ok "Working tree already clean — nothing to commit"
    else
        git commit -m "v$VERSION: release $DISPLAY_NAME $VERSION (build $NEW_BUILD)"
        ok "Committed: v$VERSION"
    fi

    info "Pushing to origin..."
    git push origin main
    ok "Pushed to origin"
fi

# --- Step 3: Archive + Export + Notarize + Staple ---
info "Archiving..."

# Clean previous build artifacts
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR"

# Archive
xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

ok "Archive created: $ARCHIVE_PATH"

# Show .app size inside archive
ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/$DISPLAY_NAME.app"
if [[ -d "$ARCHIVE_APP" ]]; then
    ARCHIVE_SIZE=$(du -sh "$ARCHIVE_APP" | cut -f1)
    info "Archive .app size: $ARCHIVE_SIZE"
fi

# Check for dSYMs (important for crash symbolication)
DSYM_PATH="$ARCHIVE_PATH/dSYMs"
if [[ -d "$DSYM_PATH" ]] && ls "$DSYM_PATH"/*.dSYM 1>/dev/null 2>&1; then
    ok "dSYMs generated (keep the archive for crash symbolication)"
else
    warn "No dSYMs found in archive"
fi

# Export with Developer ID signing (manual inside-out codesign)
# Sparkle's XPC services ship ad-hoc signed in the binary xcframework.
# xcodebuild -exportArchive fails with errSecInternalComponent when trying
# to re-sign them. The standard workaround is manual inside-out codesigning.
info "Exporting with Developer ID signing (manual codesign)..."

SIGNING_ID="$DETECTED_ID"
EXPORTED_APP="$EXPORT_PATH/$DISPLAY_NAME.app"

mkdir -p "$EXPORT_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$DISPLAY_NAME.app" "$EXPORTED_APP"
ok "Copied .app from archive"

# Sign everything inside-out: deepest nested bundles first, then outer layers.
# The archive leaves some binaries ad-hoc signed; we must re-sign them all.
SPARKLE_FW="$EXPORTED_APP/Contents/Frameworks/Sparkle.framework/Versions/B"

# 1) Sparkle's deeply nested XPC services and helpers
info "Signing Sparkle components..."
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE_FW/XPCServices/Downloader.xpc"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE_FW/XPCServices/Installer.xpc"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE_FW/Updater.app"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE_FW/Autoupdate"
ok "Sparkle helpers signed"

# 2) All dylibs in Contents/Frameworks/ (e.g., libswiftCompatibilitySpan.dylib)
info "Signing dylibs..."
find "$EXPORTED_APP/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -exec \
    codesign -fs "$SIGNING_ID" --timestamp --options runtime {} \;
ok "Dylibs signed"

# 3) All frameworks in Contents/Frameworks/ (Sparkle.framework and any others)
info "Signing frameworks..."
find "$EXPORTED_APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -exec \
    codesign -fs "$SIGNING_ID" --timestamp --options runtime {} \;
ok "Frameworks signed"

# 4) Sign main app with entitlements extracted from archive
#    The archive copy has Xcode-processed entitlements (team-identifier injected,
#    unauthorized entitlements stripped). Using these instead of the raw .entitlements
#    file avoids launch failures from iOS-only entitlements like increased-memory-limit.
info "Extracting entitlements from archive..."
codesign -d --entitlements :"$BUILD_DIR/archive-entitlements.plist" \
    "$ARCHIVE_PATH/Products/Applications/$DISPLAY_NAME.app"
ok "Archive entitlements extracted"

info "Signing main app..."
codesign -fs "$SIGNING_ID" --timestamp --options runtime \
    --entitlements "$BUILD_DIR/archive-entitlements.plist" "$EXPORTED_APP"
ok "Main app signed"

EXPORT_SIZE=$(du -sh "$EXPORTED_APP" | cut -f1)
info "Exported .app size: $EXPORT_SIZE"

# Verify code signature
codesign --verify --deep --strict "$EXPORTED_APP" 2>&1
ok "Code signature valid"

# Notarize
info "Notarizing with Apple..."
NOTARIZE_ZIP="$BUILD_DIR/notarize-$SCHEME.zip"
ditto -c -k --keepParent "$EXPORTED_APP" "$NOTARIZE_ZIP"

NOTARIZE_OUTPUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" \
    --wait 2>&1) || true

echo "$NOTARIZE_OUTPUT"

# notarytool exits 0 even on Invalid — must check status text
if echo "$NOTARIZE_OUTPUT" | grep -q "status: Invalid"; then
    SUBMISSION_ID=$(echo "$NOTARIZE_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
    warn "Fetching notarization log..."
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" 2>&1 || true
    rm -f "$NOTARIZE_ZIP"
    fail "Notarization failed (status: Invalid). See log above."
fi

rm -f "$NOTARIZE_ZIP"
ok "Notarization accepted by Apple"

# Staple the notarization ticket to the .app
info "Stapling notarization ticket..."
xcrun stapler staple "$EXPORTED_APP"
ok "Notarization ticket stapled"

# Verify Gatekeeper acceptance (should pass now)
if spctl --assess --type exec "$EXPORTED_APP" 2>&1; then
    ok "Gatekeeper accepts the app (signed + notarized + stapled)"
else
    fail "Gatekeeper rejected the app after notarization — check notarytool log"
fi

# --- Step 4: Create DMG ---
info "Creating DMG..."

# Random suffix makes the download URL unguessable
RANDOM_SUFFIX=$(head -c 8 /dev/urandom | xxd -p | head -c 8)
DMG_NAME="HitokuDraft-${VERSION}+${RANDOM_SUFFIX}.dmg"
mkdir -p "$DIST_DIR"

# Remove old DMGs matching this version
rm -f "$DIST_DIR"/HitokuDraft-"${VERSION}"*.dmg

create-dmg \
    --volname "$DISPLAY_NAME" \
    --window-size 600 400 \
    --icon-size 128 \
    --app-drop-link 450 185 \
    "$DIST_DIR/$DMG_NAME" \
    "$EXPORTED_APP"

ok "DMG created: $DIST_DIR/$DMG_NAME"
echo "    Size: $(du -sh "$DIST_DIR/$DMG_NAME" | cut -f1)"

# --- Step 5: Generate appcast ---
if [[ -n "$GENERATE_APPCAST" ]]; then
    info "Generating appcast.xml..."

    # generate_appcast expects a directory containing the DMG(s)
    # --download-url-prefix tells Sparkle where users will fetch the DMG
    "$GENERATE_APPCAST" \
        --download-url-prefix "$DMG_DOWNLOAD_BASE/" \
        "$DIST_DIR"

    if [[ -f "$DIST_DIR/appcast.xml" ]]; then
        ok "Appcast generated: $DIST_DIR/appcast.xml"
    else
        warn "generate_appcast ran but no appcast.xml found in $DIST_DIR"
    fi
else
    warn "Skipping appcast generation (generate_appcast not found)"
    echo "    Run manually: generate_appcast --download-url-prefix \"$DMG_DOWNLOAD_BASE/\" $DIST_DIR"
fi

# --- Step 6: Upload DMG to R2 ---
info "Uploading DMG to R2 ($R2_BUCKET/$APP_SLUG/$DMG_NAME)..."

npx wrangler r2 object put "$R2_BUCKET/$APP_SLUG/$DMG_NAME" \
    --file "$DIST_DIR/$DMG_NAME" \
    --remote

ok "DMG uploaded to R2: $DMG_DOWNLOAD_BASE/$DMG_NAME"

# --- Step 7: Deploy appcast to hitoku.me ---
WEBSITE_APP_DIR="$WEBSITE_REPO/apps/$APP_SLUG"

if [[ -f "$DIST_DIR/appcast.xml" ]]; then
    info "Deploying appcast.xml to hitoku.me..."
    mkdir -p "$WEBSITE_APP_DIR"
    cp "$DIST_DIR/appcast.xml" "$WEBSITE_APP_DIR/appcast.xml"
    ok "appcast.xml copied"

    pushd "$WEBSITE_REPO" > /dev/null
    git add "apps/$APP_SLUG/appcast.xml"

    if git diff --cached --quiet; then
        ok "No appcast changes — nothing to push"
    else
        git commit -m "Update appcast: $DISPLAY_NAME v$VERSION"
        git push origin main
        ok "Pushed appcast to hitoku.me (Cloudflare Pages will deploy)"
    fi
    popd > /dev/null
else
    warn "No appcast.xml found — skipping website deploy"
fi

# --- Step 8: Git tag ---
info "Tagging release..."
git tag "v$VERSION"
ok "Tagged v$VERSION"
git push origin "v$VERSION"
ok "Pushed tag v$VERSION to origin"

# --- Step 9: Summary ---
DMG_URL="$DMG_DOWNLOAD_BASE/$DMG_NAME"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  Release v$VERSION shipped!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Automated:"
echo "    - Archive:      $ARCHIVE_PATH (keep for dSYMs)"
echo "    - Exported app: $EXPORT_SIZE (signed + notarized)"
echo "    - DMG on R2:    $DMG_URL"
echo "    - appcast.xml → hitoku.me/apps/$APP_SLUG/appcast.xml"
echo "    - git tag v$VERSION → origin"
echo ""
echo "  Manual:"
echo "    Update Gumroad product with new DMG"
echo "    (Gumroad dashboard → Product → Replace file → $DIST_DIR/$DMG_NAME)"
echo ""
ok "Done!"
