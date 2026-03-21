# Changelog

All notable changes to Hitoku Draft are documented in this file.

## [Unreleased — targeting 1.2.0]

### Added
- **Qwen3.5 model support** — Qwen3.5 4B and 9B models added as bundled options, with improved multilingual quality across 200+ languages. Smart default now selects Qwen3.5 9B on 16+ GB machines.

### Security
- **License state moved from UserDefaults to Keychain** — `defaults write licenseActivated` no longer bypasses licensing.
- **HMAC-SHA256 signed license token** — activation state is cryptographically signed; forging requires binary disassembly to extract the key.
- **Launch re-verification** — license is verified with Gumroad on every cold start (was every 30 days). Offline grace period reduced from 30 to 7 days.
- **Gumroad response cross-checking** — now verifies `refunded`, `disputed`, `chargebacked` flags and echoed `license_key`, not just `success: true`.
- **Keychain items marked `WhenUnlockedThisDeviceOnly`** — not synced via iCloud Keychain, not included in backups.

### Fixed
- **Dictation no longer cuts off during natural speech pauses** — VAD `silenceAfterSpeech` flag now resets on each new `speechStart` event, so the silence countdown doesn't accumulate across pauses. Users with long captures no longer need to repeatedly press the shortcut.
- **Draft mode now follows user language requests** — removed hard-coded language override from draft prompts. Multilingual models (Qwen3, etc.) now respect explicit language instructions like "explain in English" even when the voice input is in another language.
- **Faster end-of-speech detection** — hybrid VAD + RMS silence detection. Once VAD confirms speech, RMS monitors audio level directly in the tap callback (zero pipeline delay). Whichever detects silence first wins, eliminating the ~0.5-1s lag from async VAD processing.

### Developer
- **License bypassed in debug builds** — `#if DEBUG` in `LicenseManager.init()` and `reVerifyIfNeeded()` auto-activates licensing during Xcode Run / `swift build`, eliminating Gumroad round-trips during development. Release builds (`release.sh -c release`) enforce licensing normally.

### Changed
- **Qwen3.5 output quality fix** — disabled reasoning mode via chat template context (`enable_thinking=false`) and switched to cleaner draft prompt format. Qwen3.5 now produces direct content instead of meta-analysis.
- **Qwen3.5 output now more concise** — dedicated system prompt, draft prompt, and tighter token budget (500 tokens vs 800 default) scoped to Qwen3.5 models only.
- **Simplified smart default selection** — now purely RAM-based (≥16 GB → Qwen3.5 9B, ≥8 GB → Qwen3.5 4B, <8 GB → Granite). Removed English/non-English language branching.
- **Max capture setting description clarified** — subtitle now states it applies to voice edit only, not dictation, in all 4 languages.
- **Customizable dictation overlay size** — new "Text lines" (1–3) and "Overlay width" (150–400 pt) settings in the Appearance tab let users resize the dictation pill to show more text.
- Seamless migration for existing activated users: signed token is created from existing Keychain key + UserDefaults email on first launch, then legacy UserDefaults keys are cleaned up. No re-activation required.

### Removed
- **Meta-Llama-3.1 8B 4-bit** removed from bundled defaults — redundant with Qwen3.5 4B at half the memory.
- **Qwen3 4B 4-bit** removed from bundled defaults — superseded by Qwen3.5 4B.

## [1.0.9] — 2026-03-20

### Added
- License activation and management.
- Neural voice activity detection for smarter silence handling.
- About window.

### Fixed
- Clipboard preserved correctly during grammar fix.
- Grammar fix no longer triggers on very short or empty selections.

### Changed
- Improved STT model language descriptions.
- Refined settings window sizing.

## [1.0.7] — 2026-03-18

### Added
- **Context-aware screen capture**: captures the active window's visible text before generating edits, giving the LLM richer context for smarter, more relevant output.
- Screen recording permission request and settings toggle.
- Localized strings for screen-capture feature (en, es, fr, it).

### Changed
- Edit and draft prompts now incorporate captured screen context when available.

## [1.0.6] — 2026-03-15

Version bump and Sparkle distribution update — no user-facing changes.

## [1.0.5] — 2026-03-15

### Added
- **Ghost HUD style**: new overlay variant with heavy blur and wallpaper bleed-through, now the default dictation overlay.

### Changed
- Refined dictation overlay panel positioning and layout.

## [1.0.4] — 2026-03-13

### Added
- Cached model weight cleanup: removing a custom HuggingFace model now deletes its downloaded weights from `~/Library/Caches`.
- Previous-model restore: deleting the active custom model falls back to the previously-used model instead of the smart default.

### Changed
- Improved release script with version-jump sanity checks and backwards-version warnings.

## [1.0.3] — 2026-03-13

### Added
- Release automation script (`release.sh`) for build, sign, notarize, and Sparkle appcast generation.

## [1.0.2] — 2026-03-13

### Fixed
- **Microphone sharing**: added retry delay so the mic can settle when another app (Zoom, Voice Memos) reconfigures the audio hardware; new "mic in use" error distinct from "no mic found."
- Model switching now cancels any in-progress setup/download before starting the new one.

### Changed
- Updated to latest MLXAudioSTT API (`STTGenerateParameters()` initializer).
- Sparkle auto-update integration and codesign workaround for non-App-Store distribution.

## [0.2.0] — 2026-03-12

### Added
- Persistent custom model registry with JSON config at `~/.config/hitokudraft/models.json`.
- MLX Audio STT service integration for on-device speech-to-text.
- Menu bar icon and macOS menu bar app structure.
- Localization resources (English, Spanish, French, Italian).
- Settings UI with model download progress.
- ConversationCoordinator orchestration pipeline.
