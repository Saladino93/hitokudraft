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
              Sparkle checks hitoku.me/appcast.xml
              for updates on launch
```

---

## 2. Entitlements — already correct for Developer ID

File: `VoiceEditor/VoiceEditor.entitlements`

| Entitlement | Value | Notes |
|---|---|---|
| `com.apple.security.app-sandbox` | `false` | Required — sandbox blocks CGEventPost |
| `com.apple.developer.kernel.increased-memory-limit` | `true` | Required for large LLM weights in RAM |
| `com.apple.security.network.client` | `true` | Model downloads, update checks |
| `com.apple.security.device.audio-input` | `true` | Microphone recording |
| `com.apple.security.cs.disable-library-validation` | `true` | mlx-swift loads Metal shaders dynamically — App Store would reject this |
| `com.apple.security.automation.apple-events` | `true` | Accessibility automation |

No entitlement changes are needed. Hardened Runtime (`ENABLE_HARDENED_RUNTIME = YES` in `project.yml`) is already set, which is a notarization requirement.

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
<string>https://hitoku.me/appcast.xml</string>
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
            MenuBarMenu(coordinator: coordinator, updater: updaterController.updater)
        } label: {
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
```

### d) Menu bar — `MenuBarView.swift`

Add "Check for Updates…" above the Quit item:

```swift
import Sparkle

struct MenuBarMenu: View {
    @ObservedObject var coordinator: ConversationCoordinator
    let updater: SPUUpdater
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // ... existing items ...

        Divider()

        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit Hitoku Draft") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

### e) Appcast generation (per-release)

After archiving and notarizing, run Sparkle's bundled tool:

```bash
# Path varies by SPM cache; find it with:
find ~/Library/Developer/Xcode/DerivedData -name generate_appcast 2>/dev/null

generate_appcast \
  --download-url-prefix https://github.com/your-org/hitoku-draft/releases/download/v1.0.0/ \
  ./dist/
```

Host the generated `appcast.xml` at `https://hitoku.me/appcast.xml`. Each release: upload the new DMG to GitHub Releases, regenerate the appcast, re-upload it.

---

## 4. Notarization workflow

### ExportOptions.plist (create at repo root)

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

### Archive → Export → Notarize → Staple

```bash
# 1. Archive (or use Xcode → Product → Archive)
xcodebuild archive \
  -scheme HitokuDraft \
  -archivePath HitokuDraft.xcarchive

# 2. Export with Developer ID
xcodebuild -exportArchive \
  -archivePath HitokuDraft.xcarchive \
  -exportPath ./dist \
  -exportOptionsPlist ExportOptions.plist

# 3. Zip for notarization (notarytool requires a zip or dmg)
ditto -c -k --sequesterRsrc --keepParent \
  "dist/Hitoku Draft.app" \
  dist/HitokuDraft.zip

# 4. Notarize (store credentials once with --store-credentials AC_PASSWORD)
xcrun notarytool submit dist/HitokuDraft.zip \
  --keychain-profile "AC_PASSWORD" \
  --wait

# 5. Staple the ticket to the .app
xcrun stapler staple "dist/Hitoku Draft.app"

# 6. Validate
xcrun stapler validate "dist/Hitoku Draft.app"
```

Store your Apple ID notarization credentials once:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
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

## 6. Gumroad product setup

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

## 7. Release checklist

### One-time setup

- [ ] Add Sparkle to `project.yml` (packages + dependency)
- [ ] Add `SUFeedURL` and `SUEnableAutomaticChecks` to `VoiceEditor/Info.plist`
- [ ] Wire `SPUStandardUpdaterController` in `VoiceEditorApp.swift`
- [ ] Add "Check for Updates…" item to `MenuBarView.swift`
- [ ] Bump `MARKETING_VERSION` to `1.0.0` in `project.yml` (currently `0.1.0`)
- [ ] Create `ExportOptions.plist` at repo root (Developer ID config)
- [ ] Set up `hitoku.me/appcast.xml` endpoint (GitHub Pages or server)
- [ ] Install `create-dmg`: `brew install create-dmg`
- [ ] Locate Sparkle's `generate_appcast` binary (built with SPM)
- [ ] Store notarization credentials: `xcrun notarytool store-credentials`
- [ ] Create Gumroad account and product
- [ ] Create Privacy Policy page on `hitoku.me` (required by Gumroad)
- [ ] App icon: 1024×1024 px PNG (no alpha) — wire `icon_app.png` in `Assets.xcassets`
- [ ] Verify model licenses allow Gumroad distribution:
  - Qwen3 (Alibaba): check commercial terms at [qwen license](https://huggingface.co/Qwen)
  - Granite 4 (IBM): Apache 2.0 — OK
  - LFM2.5: verify license terms
  - FluidAudio bundled models: verify license terms

### Per-release

- [ ] Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`
- [ ] Archive → Export (Developer ID) using `ExportOptions.plist`
- [ ] Notarize with `xcrun notarytool submit --wait`
- [ ] Staple with `xcrun stapler staple`
- [ ] Validate with `xcrun stapler validate`
- [ ] Package DMG with `create-dmg`
- [ ] Run `generate_appcast` on the new DMG
- [ ] Upload DMG to GitHub Releases
- [ ] Update and upload `appcast.xml` to `hitoku.me/appcast.xml`
- [ ] Update Gumroad product file with new DMG
- [ ] Tag the git release: `git tag v1.0.0 && git push origin v1.0.0`

---

## 8. Verification

| Check | Command / Action |
|---|---|
| Build with Sparkle | `xcodegen generate && xcodebuild build -scheme HitokuDraft` |
| "Check for Updates…" appears | Launch app, open menu bar menu |
| Sparkle connects to appcast | Point `SUFeedURL` at a test appcast, click "Check for Updates…" |
| Notarization valid | `xcrun stapler validate "dist/Hitoku Draft.app"` → `The validate action worked!` |
| Gatekeeper passes | `spctl --assess --type exec "dist/Hitoku Draft.app"` → `accepted` |
| DMG mounts cleanly | Double-click DMG on a clean machine |
| Sparkle update prompt | Serve a higher-version appcast, click "Check for Updates…" |
