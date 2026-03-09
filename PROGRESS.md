# VoiceEditor — Progress Log

**Platform:** macOS (Apple Silicon only · no App Store · no sandbox)
**Stack:** SwiftUI + mlx-swift + FluidAudio
**Version:** v0.1-alpha (pre-release)
**Last updated:** 2026-03-09 (session 2)

---

## Architecture

| Module | Role |
|---|---|
| `AppShell` | App entry point, menu bar lifecycle |
| `ConversationCoordinator` | Single orchestration center (pipeline owner) |
| `ModelManager` | MLX model loading / switching |
| `MLXLLMService` | LLM inference via mlx-swift |
| `AudioCaptureService` | Microphone capture, VAD, silence detection |
| `TextCaptureService` | Accessibility-based text capture from focused field |
| `FluidAudio STT` | Speech-to-text transcription |
| `PermissionsCoordinator` | Mic + Accessibility permission gating |
| `HotkeyManager` | Global hotkey registration |
| `SettingsView` | Model selection, hotkey config, preferences |
| `MenuBarView` | Menu bar popover UI |
| `DictationOverlayPanel` | Floating HUD shown during active dictation |

---

## Sessions

### 2026-03-09 (session 2) — Distribution setup: Gumroad + Sparkle

**Decision:** App Store distribution abandoned. Core blocker: `CGEvent.post(tap: .cghidEventTap)`
in `TextCaptureService.swift:68-79` is prohibited by the App Store sandbox. Pivoting to
**Gumroad** (purchase) + **Sparkle** (auto-update) with Developer ID signing.

**Files created:**
- `DISTRIBUTION.md` — full release guide (strategy, entitlements, Sparkle setup, notarization,
  DMG packaging, Gumroad product, one-time + per-release checklists, verification table)
- `ExportOptions.plist` — Developer ID export config (`method: developer-id`, team `R4S8W6UC7K`)

**Files modified:**
- `project.yml` — added Sparkle 2.0+ package + dependency on `HitokuDraft` target
- `VoiceEditor/Info.plist` — added `SUFeedURL` (`https://hitoku.me/appcast.xml`) and
  `SUEnableAutomaticChecks = true`
- `VoiceEditorApp.swift` — `import Sparkle`, added `@State SPUStandardUpdaterController`,
  passes `.updater` to `MenuBarMenu`
- `MenuBarView.swift` — `import Sparkle`, added `let updater: SPUUpdater` param,
  added "Check for Updates…" button (disabled when `!updater.canCheckForUpdates`)

**Entitlements:** All existing entitlements confirmed correct for Developer ID — no changes needed.
`disable-library-validation` is required for mlx-swift Metal shader loading and would block
App Store review; this is fine under Developer ID.

**Future App Store path (when needed):** Requires replacing `CGEvent.post()` with a
privileged helper tool or different text injection approach. Not blocking anything now.

---

### 2026-03-09 (session 1) — Settings UI polish

- **Model tab:** Replaced radio rows with a Picker dropdown; uses native macOS subtitle
  support (experience description as primary label, model name as subtitle —
  Phil Zakharchenko technique).
- **Bundled model defaults:** Full 6-model `bundledDefaults` set —
  Qwen3 4B / 8B (4-bit), Granite 4 1B (4-bit / 8-bit), LFM2.5 1.2B (4-bit / 8-bit).
- **Custom model row:** Load Model button de-emphasized (`.bordered` instead of
  `.borderedProminent`) to keep visual hierarchy clean.
- **Status row:** "Ready" text enlarged to 15 pt; green indicator dot enlarged to 9 × 9.
- **Disclaimer text:** Yellow, 18 pt, extra top padding.
- **Global type style:** `.fontDesign(.rounded)` applied to the entire `SettingsView`.

---

## Repo status (2026-03-09)

- **Branch:** `main`
- **Commits:** 4 (initial → remove temp files → updating stage → clean)

**Modified (uncommitted):**
`Package.swift`, `Info.plist`, `ModelOption.swift`, `ConversationCoordinator.swift`,
`AudioCaptureService.swift`, `MLXLLMService.swift`, `SoundPlayer.swift`,
`TextCaptureService.swift`, `ThreadSafeAudioBuffer.swift`,
`DictationOverlayPanel.swift`, `MenuBarView.swift`, `SettingsView.swift`,
`VoiceEditor.entitlements`, `.gitignore`, `text.txt`

**Untracked (pending decision):**
`ACKNOWLEDGMENTS.md`, `Assets.xcassets/`, `Utilities/`, `AcknowledgmentsView.swift`,
`bundle.sh`, `icon_app.png`, `project.yml`

---

## TODO / Things to improve

### Distribution (one-time, before v1.0 launch)
- [ ] Run `xcodegen generate` and verify build succeeds with Sparkle
- [ ] Bump `MARKETING_VERSION` to `1.0.0` in `project.yml` (currently `0.1.0`)
- [ ] Set up `hitoku.me/appcast.xml` endpoint (GitHub Pages or server)
- [ ] Store notarization credentials: `xcrun notarytool store-credentials`
- [ ] Install `create-dmg`: `brew install create-dmg`
- [ ] Create Gumroad account + product (see `DISTRIBUTION.md` §6)
- [ ] Create Privacy Policy page on `hitoku.me` (Gumroad requirement)
- [ ] App icon: wire `icon_app.png` into `Assets.xcassets` (1024×1024 PNG, no alpha)
- [ ] Verify model licenses for Gumroad distribution (Qwen3, LFM2.5, FluidAudio)

### Core app
- [ ] Commit all in-progress changes
- [ ] Output cleaning: strip LLM preamble ("Sure, here is…") before paste
- [ ] `SFSpeechRecognizer` fallback while FluidAudio models are downloading
- [ ] Model download cancellation UI (progress bar + cancel button)
- [ ] Dictation overlay panel: final UX polish pass
- [ ] Grammar fix: expand language coverage beyond EN / IT / FR / DE
- [ ] Test clipboard restore on failure / cancellation paths
- [ ] Model config live-reload from `~/.config/hitokudraft/models.json`
- [ ] Onboarding flow: first-launch checklist (Accessibility + Mic permissions)
