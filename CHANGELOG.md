# Changelog

All notable changes to Hitoku Draft are documented in this file.

## [Unreleased]

### Added

- **"None" LLM option** — First entry in the LLM picker disables the language model entirely. Voice edit pastes the raw STT transcript directly; grammar fix silently no-ops. Saves 2–7 GB RAM when transcription without editing is sufficient.
- **Auto-offload models** — New toggle in the Models tab releases both LLM and STT weights after 5 minutes of inactivity. Models reload from local cache on next use. Default: on.

### Fixed

- **Qwen3.5 inline markdown cleaned** — Qwen3.5 output no longer includes `**bold**` or `*italic*` markers in pasted text. Stripping is scoped to Qwen3.5 only; other model families are unaffected.

### Developer

- **Streaming LLM output** — `LLMService` protocol gains `generateStream()` returning `AsyncThrowingStream<String, Error>`; `MLXLLMService` implements it. `ConversationCoordinator` publishes `streamingLLMText` (accumulated token stream, available for future UI use). Post-processing (`OutputCleaner`, `stripEcho`) runs on the final accumulated string before paste. Grammar fix continues to use batch `generate()`. The overlay shows "Generating…" status; raw tokens are not displayed in the overlay.

- **Lazy LLM warmup** — LLM no longer loads at app launch. `setup()` only loads STT + VAD; the LLM loads on the first hotkey press via the existing `ensureLLMReady()` path. App opens instantly and Settings are fully accessible without a loading spinner. No behavior change for users who trigger a hotkey immediately.

- **Prompt templates externalized to JSON** — all system prompts and edit/draft templates moved from hardcoded Swift to `PromptsConfig.json`. Power users can override via `~/Library/Application Support/HitokuDraft/prompts.json`. Templates use `{{text}}`, `{{instruction}}`, `{{langRule}}`, `{{contextBlock}}` placeholder tokens. Public API unchanged; 3-level fallback chain (user override → bundled JSON → hardcoded Swift constants). "Open in Finder" button added to Models tab.

- **STT protocol type-cast eliminated** — `TranscriptionPipeline` no longer casts `stt as? MLXAudioSTTService` to access streaming. New `StreamingSession` protocol (defined in `STTService.swift`) abstracts `StreamingInferenceSession`'s three public methods; `MLXAudioSTTService` overrides `makeStreamingSession()` from the `STTService` protocol. Retroactive conformance via `extension StreamingInferenceSession: @retroactive StreamingSession {}`.

- **Multi-turn follow-up commands** — after a successful voice edit, the last `(instruction, result)` pair is stored. If the next command has no selected text and arrives within 5 minutes, the prior result is injected as context so the LLM can refine without re-selecting. New selection always clears the context. STT-only mode (None LLM) is unaffected.

- **AppDomainHint refactored — data-driven config** — all hard-coded browsers, app-name rules, and hint texts moved to `AppDomainConfig.json`. New categories and apps can be added without any Swift changes. Hint texts simplified to short style tags (`"email — professional tone"`) replacing verbose conditional sentences. `AppCategory` enum removed; `AppDomainHint` is now a thin JSON loader with the same public API.

- **Architecture refactor — ConversationCoordinator** — seven first-principles issues addressed; no user-facing behavior changes.
  - `DictationOverlayPanel` decoupled from coordinator: removed 25 direct call sites, replaced with Combine subscriptions on two new `@Published` properties (`liveTranscriptionText`, `activeRecordingSession`). Overlay now reacts to state via `observe(coordinator:)` instead of being commanded imperatively.
  - `runStreamingTranscription` extracted into `TranscriptionPipeline.swift` (free async function). `ConversationCoordinator` drops from ~900 to ~744 lines.
  - `activateLLM(_:drainAfter:afterLoad:)` helper eliminates the LLM load→warmup→idle try/catch pattern that was copy-pasted across `setup()`, `switchModel()`, and `downloadAndAddCustomModel()`.
  - `SilenceDetectionState` private struct in `AudioCaptureService` deduplicates ~80 lines of identical VAD + RMS tap-callback logic shared between `recordUntilSilence` and `ContinuousSession`.
  - `contextAwareMode` changed from a computed property (re-read UserDefaults on every call) to a `@Published` stored property updated by the existing `didChangeNotification` handler.
  - `nonisolated(unsafe) var lastConfirmed` in the native-streaming path replaced with the existing `LockedString` type.
  - `ModelManager.loadAll()` (dead code, never called) deleted.

## [1.2.1] — 2026-03-21

### Fixed
- **Dictation overlay text now visible in 1-line mode** — text was not appearing when overlay line count was set to 1. Replaced manual text trimming with native SwiftUI truncation for better performance and reliability.

## [1.2.0] — 2026-03-21

### Changed
- **Qwen3.5 output now more concise** — dedicated system prompt, draft prompt, and tighter token budget (500 tokens vs 800 default) scoped to Qwen3.5 models only.
- **Simplified smart default selection** — now purely RAM-based (≥16 GB → Qwen3.5 9B, ≥8 GB → Qwen3.5 4B, <8 GB → Granite). Removed English/non-English language branching.
- **Max capture setting description clarified** — subtitle now states it applies to voice edit only, not dictation, in all 4 languages.

### Removed
- **Meta-Llama-3.1 8B 4-bit** removed from bundled defaults — redundant with Qwen3.5 4B at half the memory.
- **Qwen3 4B 4-bit** removed from bundled defaults — superseded by Qwen3.5 4B.

## [1.1.0] — 2026-03-20

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
- **Customizable dictation overlay size** — new "Text lines" (1–3) and "Overlay width" (150–400 pt) settings in the Appearance tab let users resize the dictation pill to show more text.
- Seamless migration for existing activated users: signed token is created from existing Keychain key + UserDefaults email on first launch, then legacy UserDefaults keys are cleaned up. No re-activation required.

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
