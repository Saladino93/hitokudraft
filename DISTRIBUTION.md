# Hitoku Draft — Distribution Guide (Gumroad + Sparkle)

## 1. Distribution strategy

Hitoku Draft is distributed via **Gumroad** (purchase) + **Sparkle** (auto-update), signed with a **Developer ID** certificate outside the App Store sandbox.

### Why not the App Store?

The core capture loop in `VoiceEditor/Services/TextCaptureService.swift:68-79` posts synthetic `CGEvent` keystrokes (`CGEvent.post(tap: .cghidEventTap)`) to drive Cmd+C / Cmd+V. The App Store sandbox explicitly prohibits `CGEventPost`, making it impossible to ship this feature there without a full architectural rewrite.

Developer ID distribution avoids the sandbox entirely and preserves:
- `CGEventPost` for keyboard simulation
- `AXIsProcessTrusted()` for accessibility automation
- `com.apple.security.cs.disable-library-validation` for mlx-swift Metal shader loading
- ~5–10% Gumroad fee vs 30% Apple tax
- Auto-update parity with App Store via Sparkle

### Flow

```
Gumroad checkout → download DMG → drag-to-Applications install
                    ↕
              Sparkle checks hitoku.me/apps/hitokudraft/appcast.xml
              for updates on launch
```

---

## 2. Entitlements — already correct for Developer ID

File: `VoiceEditor/VoiceEditor.entitlements`

| Entitlement | Value | Notes |
|---|---|---|
| `com.apple.security.app-sandbox` | `false` | Required — sandbox blocks CGEventPost |
| `com.apple.security.network.client` | `true` | Model downloads, update checks |
| `com.apple.security.device.audio-input` | `true` | Microphone recording |
| `com.apple.security.cs.disable-library-validation` | `true` | mlx-swift loads Metal shaders dynamically — App Store would reject this |
| `com.apple.security.automation.apple-events` | `true` | Accessibility automation |

Hardened Runtime (`ENABLE_HARDENED_RUNTIME = YES` in `project.yml`) is already set, which is a notarization requirement.

> **Removed in v1.0.1:** `com.apple.developer.kernel.increased-memory-limit` was removed because it is an **iOS-only** entitlement. On macOS, it has no effect — macOS processes already have access to all available RAM. Under `xcodebuild -exportArchive`, Xcode silently strips unauthorized entitlements, so it was harmless. But with manual codesigning (needed for Sparkle XPC, see §4), the entitlement is passed verbatim, and macOS rejects the app at launch with **POSIX error 153** (unauthorized entitlement). The fix is simple: don't include it.

---

## 3. Sparkle integration

### a) Add Sparkle to `project.yml`

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.0.0

targets:
  HitokuDraft:
    dependencies:
      - package: Sparkle
        product: Sparkle
```

### b) `Info.plist` keys

```xml
<key>SUFeedURL</key>
<string>https://hitoku.me/apps/hitokudraft/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>EqgkdjSE/dGbY5loypfWqESABQXl558qO4jx7SBWIQc=</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

### c) App entry point — `VoiceEditorApp.swift`

```swift
import SwiftUI
import Sparkle

@main
struct VoiceEditorApp: App {
    @StateObject private var coordinator = ConversationCoordinator()
    // Sparkle controller must be @State so it survives App struct re-renders
    @State private var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(coordinator: coordinator)
        } label: {
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator, updater: updaterController.updater)
        }
    }
}
```

### d) Update checking — Settings only

"Check for Updates…" lives in the **Updates tab of SettingsView**, not in the menu bar menu. This keeps the menu bar dropdown minimal (status + preferences + quit). The `SPUUpdater` instance is passed from `VoiceEditorApp` → `SettingsView`, which renders the update button and auto-check toggle.

### e) Appcast generation (per-release)

After archiving and notarizing, run Sparkle's bundled tool:

```bash
# Path varies by SPM cache; find it with:
find ~/Library/Developer/Xcode/DerivedData -name generate_appcast 2>/dev/null

generate_appcast \
  --download-url-prefix https://github.com/your-org/hitoku-draft/releases/download/v1.0.0/ \
  ./dist/
```

Host the generated `appcast.xml` at `https://hitoku.me/apps/hitokudraft/appcast.xml`. Each release: upload the new DMG, regenerate the appcast, re-upload it.

---

## 4. Build pipeline — Xcode archive + manual inside-out codesign

### Build scripts

| Script | Purpose | When to use |
|---|---|---|
| `release.sh` | **Full release pipeline** — archive, inside-out codesign, notarize, DMG, upload, tag | Shipping a release |
| `bundle.sh` | Quick SPM build → `.app` (ad-hoc signed) | Dev iteration / local testing |
| `build.sh` | Minimal SPM build → `.app` (ad-hoc signed) | Fastest dev builds |

**For distribution, always use `release.sh`** (or the manual steps below). The SPM scripts (`bundle.sh`, `build.sh`) are for development only — they skip Info.plist preprocessing, dead code stripping, dSYM generation, proper signing, and notarization.

### Why manual codesign instead of `xcodebuild -exportArchive`

Sparkle's XPC services (`Downloader.xpc`, `Installer.xpc`) ship **ad-hoc signed** in the binary xcframework. When `xcodebuild -exportArchive` tries to re-sign them with a Developer ID certificate, it fails with `errSecInternalComponent` — the ad-hoc signatures conflict with the re-signing step.

The standard Sparkle workaround is **manual inside-out codesigning**: copy the `.app` from the archive, then `codesign` from the deepest nested bundles outward (XPC services → helpers → dylibs → frameworks → main app). This gives you full control over each bundle's signing.

### Why Xcode archive, not `swift build`

`swift build` doesn't:
- Preprocess Info.plist (leaves `$(MARKETING_VERSION)` as literal text → macOS rejects the bundle)
- Strip debug symbols or dead code (binary ~2× larger)
- Generate dSYMs (no crash symbolication)
- Compile asset catalogs into `.car` files
- Copy Sparkle sub-bundles (Updater.app, Downloader.xpc)
- Sign with Developer ID or notarize

### Release build settings (`project.yml`)

```yaml
configs:
  Release:
    SWIFT_OPTIMIZATION_LEVEL: "-Osize"     # smaller code vs -O (speed)
    GCC_OPTIMIZATION_LEVEL: s              # -Os for C/C++ (BoringSSL, etc.)
    DEAD_CODE_STRIPPING: "YES"             # ld -dead_strip — removes unreachable code
    COPY_PHASE_STRIP: "YES"                # strip binary during copy
    DEPLOYMENT_POSTPROCESSING: "YES"        # enable post-processing (stripping)
    STRIP_INSTALLED_PRODUCT: "YES"          # strip the installed binary
    STRIP_STYLE: all                        # strip all symbols (not just debug)
```

These settings reduce the binary from ~69MB (unstripped SPM) to ~30MB (Xcode archive).

### ExportOptions.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>R4S8W6UC7K</string>
</dict>
</plist>
```

### Manual archive + inside-out codesign (if not using `release.sh`)

```bash
# 1. Regenerate Xcode project (if project.yml changed)
xcodegen generate

# 2. Archive (builds + embeds frameworks, but does NOT sign for distribution)
xcodebuild archive \
  -project HitokuDraft.xcodeproj \
  -scheme HitokuDraft \
  -configuration Release \
  -archivePath build/HitokuDraft.xcarchive

# 3. Copy .app from archive
mkdir -p build/export
cp -R "build/HitokuDraft.xcarchive/Products/Applications/Hitoku Draft.app" \
  "build/export/Hitoku Draft.app"

# 4. Inside-out codesign (deepest bundles first)
SIGNING_ID="Developer ID Application: Your Name (R4S8W6UC7K)"
APP="build/export/Hitoku Draft.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

# 4a. Sparkle XPC services and helpers
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE/XPCServices/Downloader.xpc"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE/XPCServices/Installer.xpc"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE/Updater.app"
codesign -fs "$SIGNING_ID" --timestamp --options runtime "$SPARKLE/Autoupdate"

# 4b. All dylibs
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -exec \
  codesign -fs "$SIGNING_ID" --timestamp --options runtime {} \;

# 4c. All frameworks
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -exec \
  codesign -fs "$SIGNING_ID" --timestamp --options runtime {} \;

# 4d. Extract Xcode-processed entitlements from archive, then sign main app
codesign -d --entitlements :build/archive-entitlements.plist \
  "build/HitokuDraft.xcarchive/Products/Applications/Hitoku Draft.app"
codesign -fs "$SIGNING_ID" --timestamp --options runtime \
  --entitlements build/archive-entitlements.plist "$APP"

# 5. Verify signature
codesign --verify --deep --strict "$APP"

# 6. Notarize (signing alone is not enough — Gatekeeper requires notarization)
ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip \
  --keychain-profile "HitokuDraft" \
  --wait

# 7. Staple the notarization ticket (allows offline Gatekeeper verification)
xcrun stapler staple "$APP"

# 8. Verify Gatekeeper
spctl --assess --type exec "$APP"
```

The archive also produces dSYMs at `build/HitokuDraft.xcarchive/dSYMs/` — keep these for crash symbolication.

> **Why extract entitlements from the archive?** Xcode processes entitlements during archiving: it injects `application-identifier` and `com.apple.developer.team-identifier`, and strips iOS-only entitlements. The raw `.entitlements` file in the repo doesn't have these injected values. Using archive-extracted entitlements ensures the signed app has exactly what macOS expects.

> **Deprecation note:** The `codesign -d --entitlements :-` syntax (colon + dash for stdout) is deprecated in newer Xcode toolchains. Use `codesign -d --entitlements :path` to write to a file instead.

### One-time: store notarization credentials

```bash
xcrun notarytool store-credentials "HitokuDraft" \
  --apple-id you@example.com \
  --team-id R4S8W6UC7K \
  --password <app-specific-password>
```

---

## 5. DMG packaging

Install `create-dmg` once:

```bash
brew install create-dmg
```

Package the notarized app:

```bash
create-dmg \
  --volname "Hitoku Draft" \
  --window-size 600 400 \
  --icon-size 128 \
  --app-drop-link 450 185 \
  "HitokuDraft-1.0.0.dmg" \
  "dist/Hitoku Draft.app"
```

The resulting DMG is what you upload to Gumroad and GitHub Releases.

---

## 6. Licensing security model

### Architecture (as of 1.1.0)

License state is stored as an **HMAC-SHA256 signed token** in the macOS Keychain, not in UserDefaults. The token contains email, activation timestamp, last verification timestamp, and a cryptographic signature covering all fields plus the license key.

```
Activation flow:
  User enters key → POST to api.gumroad.com/v2/licenses/verify
    → Validate: success, uses ≤ 2, not refunded/disputed/chargebacked
    → Cross-check echoed license_key matches what we sent
    → Save key to Keychain (WhenUnlockedThisDeviceOnly)
    → Create HMAC-signed token → save to Keychain
    → isActivated = true

App launch:
  Load key + token from Keychain → verify HMAC signature
    → If valid: isActivated = true, try online re-verification
    → If online verify succeeds: update token with fresh timestamp
    → If online verify fails (revoked/refunded): deactivate
    → If offline: allow up to 7-day grace, then deactivate
    → If HMAC invalid or missing: isActivated = false
```

### What this defends against

| Attack | Blocked? | Notes |
|---|---|---|
| `defaults write ... licenseActivated true` | **Yes** | Activation state not in UserDefaults |
| MITM proxy returning `{"success": true}` | **Partially** | Must also fake refund/dispute/chargeback fields + echo the correct license key |
| Keychain item forgery | **Partially** | Must forge a valid HMAC signature (requires extracting the key from the binary) |
| 30-day offline abuse | **Yes** | Reduced to 7-day grace; re-verification on every cold start |
| Sparkle update hijack | **Yes** | EdDSA signed (pre-existing, unchanged) |

### What this does NOT defend against

- Binary disassembly to extract the HMAC key (Tier 3 mitigation: compile-time key obfuscation)
- A determined reverse engineer with Hopper/Ghidra (no client-side DRM is unbreakable)

### Keychain items

| Account | Content | Accessibility |
|---|---|---|
| `gumroad-license-key` | Raw license key string | `WhenUnlockedThisDeviceOnly` |
| `license-token` | JSON: `{email, activatedAt, lastVerifiedAt, signature}` | `WhenUnlockedThisDeviceOnly` |

Service for both: `com.hitokudraft.license`

### Migration from pre-1.1.0

On first launch after update, `LicenseManager.init()` detects the old `licenseActivated` UserDefaults flag, reads the existing Keychain key, creates a signed token, and cleans up legacy UserDefaults entries. Existing users are not asked to re-activate.

---

## 7. Gumroad product setup

1. Create account at [gumroad.com](https://gumroad.com)
2. New product → **Digital product** → upload the notarized `.dmg`
3. Suggested price: **$19–29** one-time (local-LLM productivity niche)
4. Product description must include:
   - Apple Silicon only (no Intel)
   - macOS 14 Sonoma or later
   - AI models (~2–4 GB) downloaded on first launch
   - No subscription, no cloud
5. Support URL: `https://hitoku.me`
6. Set `hitoku.me` as a custom domain in Gumroad settings for a branded checkout URL

---

## 8. Release checklist

### One-time setup

- [x] Add Sparkle to `Package.swift` (packages + dependency)
- [x] Add `SUFeedURL`, `SUPublicEDKey`, and `SUEnableAutomaticChecks` to `VoiceEditor/Info.plist`
- [x] Wire `SPUStandardUpdaterController` in `VoiceEditorApp.swift`
- [x] Add "Check for Updates…" in SettingsView (Updates tab — intentionally not in menu bar)
- [x] Create `ExportOptions.plist` at repo root (Developer ID config)
- [x] Bump `MARKETING_VERSION` to `1.0.0` in `project.yml` (now at `1.0.1`)
- [x] Set up `hitoku.me/apps/hitokudraft/appcast.xml` endpoint (Cloudflare Pages)
- [x] Install `create-dmg`: `brew install create-dmg`
- [x] Locate Sparkle's `generate_appcast` binary (built with SPM)
- [x] Store notarization credentials: `xcrun notarytool store-credentials`
- [x] Create Gumroad account and product
- [ ] Create Privacy Policy page on `hitoku.me` (required by Gumroad)
- [x] App icon: 1024×1024 px PNG (no alpha) — wire `icon_app.png` in `Assets.xcassets`
- [ ] Verify model licenses allow Gumroad distribution:
  - Qwen3 (Alibaba): check commercial terms at [qwen license](https://huggingface.co/Qwen)
  - Granite 4 (IBM): Apache 2.0 — OK
  - LFM2.5: verify license terms
  - FluidAudio bundled models: verify license terms

### Per-release (automated by `release.sh`)

All steps below are handled by `./release.sh [VERSION]`:

- [ ] Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`
- [ ] `xcodegen generate` (regenerate Xcode project)
- [ ] `xcodebuild archive` → manual inside-out codesign (Developer ID signing)
- [ ] `xcrun notarytool submit --wait` (Apple notarization)
- [ ] `xcrun stapler staple` (embed notarization ticket)
- [ ] Package DMG with `create-dmg`
- [ ] Run `generate_appcast` on the new DMG
- [ ] Upload DMG to Cloudflare R2 (`downloads.hitoku.me`)
- [ ] Push `appcast.xml` to hitokume repo → Cloudflare Pages
- [ ] Tag the git release: `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] **Manual**: Update Gumroad product file with new DMG

---

## 9. Verification

| Check | Command / Action |
|---|---|
| Build with Sparkle | `xcodegen generate && xcodebuild build -scheme HitokuDraft` |
| "Check for Updates…" appears | Launch app, open menu bar menu |
| Sparkle connects to appcast | Point `SUFeedURL` at a test appcast, click "Check for Updates…" |
| Notarization valid | `xcrun stapler validate "dist/Hitoku Draft.app"` → `The validate action worked!` |
| Gatekeeper passes | `spctl --assess --type exec "dist/Hitoku Draft.app"` → `accepted` |
| DMG mounts cleanly | Double-click DMG on a clean machine |
| Sparkle update prompt | Serve a higher-version appcast, click "Check for Updates…" |

---

## 10. Local testing on a single Mac

### A) Test the Sparkle update flow

1. Build v1.0 and install to `/Applications`
2. Build v1.1 with a bumped version
3. Create a DMG of v1.1 and run `generate_appcast` on it
4. Spin up a local server with the test appcast:
   ```bash
   cd dist/
   python3 -m http.server 8080
   ```
5. Temporarily override the feed URL:
   ```bash
   defaults write com.hitokudraft.app SUFeedURL "http://localhost:8080/appcast.xml"
   ```
6. Launch the v1.0 app — Sparkle should show the v1.1 update prompt
7. After testing, remove the override:
   ```bash
   defaults delete com.hitokudraft.app SUFeedURL
   ```

### B) Test Gatekeeper (the customer experience)

Gatekeeper trusts apps you built locally. To simulate a first-launch on a "clean" machine:

**Option 1: Separate macOS user account (no extra Mac needed)**
- System Settings → Users & Groups → Add User
- Log in as that user, download the DMG from a browser (gets quarantine xattr)
- Open the app — should show "Apple checked it for malicious software"

**Option 2: Manual quarantine simulation**
```bash
cp -R "build/VoiceEditor.app" /tmp/
xattr -w com.apple.quarantine "0081;$(printf '%x' $(date +%s));Safari;$(uuidgen)" /tmp/VoiceEditor.app
open /tmp/VoiceEditor.app
```

**Option 3: Another Mac or a friend** — best for true end-to-end.

### C) What requires another Mac?

| What you're testing | Another Mac needed? | Alternative |
|---|---|---|
| Build + sign + notarize | No | Your current Mac works |
| Sparkle update flow | No | Local server with test appcast |
| Gatekeeper first-launch | Recommended | Separate user account or xattr trick |
| Clean-machine experience | Yes | No substitute for fresh Accessibility, no cached models, etc. |
| Different RAM tiers | Yes | Can't simulate 8GB vs 48GB on one machine |

---

## 11. Release automation

Use `release.sh` for the full per-release workflow:

```bash
# Interactive (prompts for version)
./release.sh

# Non-interactive
./release.sh 1.0.0

# Dry run (shows what would happen)
./release.sh 1.0.0 --dry-run
```

The script automates: version bump → `xcodegen generate` → `xcodebuild archive` → manual inside-out codesign (Developer ID) → notarize → staple → DMG creation → appcast generation → R2 upload → appcast deploy → git tagging.

### Hosting architecture

DMGs are hosted on **Cloudflare R2** (the `hitokudraft` bucket) and served via `downloads.hitoku.me`. The appcast.xml is served from **Cloudflare Pages** via the `hitokume` git repo at `hitoku.me/apps/hitokudraft/appcast.xml`.

```
Sparkle update flow:
  App → hitoku.me/apps/hitokudraft/appcast.xml       (Cloudflare Pages)
      → downloads.hitoku.me/hitokudraft/HitokuDraft-*.dmg  (R2)

release.sh:
  xcodegen → xcodebuild archive → inside-out codesign → notarize → staple → DMG → appcast
    ├── wrangler r2 object put → DMG to R2 bucket
    ├── git push appcast.xml → hitokume repo → Cloudflare Pages
    └── git tag → hitokudraft repo
```

R2 was chosen over git-based DMG hosting because Cloudflare Pages has a 25 MB per-file limit.
