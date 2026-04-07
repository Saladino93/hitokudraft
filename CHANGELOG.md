# Changelog

All notable changes to Hitoku Draft are documented in this file.

## [Unreleased]

### Added
- **Voice readback** — TTS in display/non-editable mode (e.g. reading a PDF with Ctrl+Z). Two engines: Kokoro (multi-voice, speed control) and PocketTTS (flow-matching). Streaming TTS with prefetch synthesis, adaptive chunking, and segment highlighting in the overlay.
- **Browser context** — Full-page text extraction from Safari, Chrome, Arc, Brave, and Edge via AppleScript JavaScript. Data-driven browser registry for easy extensibility.
- **Vision Language Model support** — Qwen3.5 models load via MLXVLM and can see window screenshots in Advanced context mode. The LLM describes images, charts, and UI on screen.
- **Web search** — LLM can search the web during generation via DuckDuckGo (no API key). Toggle "Allow internet access" in Settings → General. Also includes URL fetching for reading articles.
- **Chat data models** — ChatMessage, Conversation, and ChatStore scaffolded for future persistent conversation history.

### Fixed
- **Safari treated as editable** — AXWebArea role now has a refinement check (settable text range) to distinguish read-only articles from web editors like Gmail/Notion.
- **Esc key system alert sound** — CGEventTap suppresses the Esc key globally when the display overlay is visible.
- **PocketTTS voice compatibility** — Filtered to voices with 125-frame prompt length (the only format FluidAudio supports).

## [1.4.2] — 2026-04-05

### Fixed
- **Calendar action always failed with "Calendar access denied"** — Three layered issues: (1) the calendar entitlement was missing from the signed binary (fixed in v1.4.1); (2) `requestWriteOnlyAccessToEvents()` was used, but write-only access does not allow reading `EKEventStore.defaultCalendarForNewEvents`, so event creation would fail regardless — switched to `requestFullAccessToEvents()`; (3) `NSCalendarsFullAccessUsageDescription` was missing from Info.plist, causing macOS 14+ to silently deny `requestFullAccessToEvents()` without showing any permission dialog.
- **Reminders action always failed with "Reminders access denied"** — `requestAccess(to: .reminder)` is deprecated on macOS 14+ and was silently returning false. Switched to `requestFullAccessToReminders()` (macOS 14+). Added the required `NSRemindersFullAccessUsageDescription` key to Info.plist.
- **Action Mode silently did nothing when STT was not loaded** — Ctrl+A with no text selected delegates to Action Mode, which requires the speech model to record a voice command. `handleGrammarFix()` was calling `ensureLLMReady()` but not `ensureSTTReady()`, so the STT guard in `ActionCoordinator.handle()` silently returned. STT is now loaded on-demand before entering Action Mode.
- **Action timer duration treated as 0 when LLM output a float** — `duration_seconds` and `duration_minutes` were parsed with `as? Int`, which fails when the LLM outputs `600.0` instead of `600`. Both fields now coerce through `NSNumber.doubleValue` to tolerate float-formatted integers.
- **No way to cancel an in-progress generation** — grammar-fix LLM generation ran without a stored task handle, making it uncancellable. The pipeline is now wrapped in a `grammarFixTask` (mirroring `voiceEditTask` for voice edit). A "Stop" button appears in the menu bar during any active operation (listening, transcribing, generating) and cancels immediately.

## [1.4.1] — 2026-04-05

### Fixed
- **Calendar action permission dialog never appeared** — the release signing step was extracting entitlements from the `.app` bundle rather than the main executable binary. `codesign -d --entitlements` on a bundle concatenates the entitlements of every nested artifact (Sparkle XPC helpers, Autoupdate binary, frameworks…) into one file; when that multi-plist file was then used to re-sign the main app, `codesign` only read the first block (a Sparkle helper, which carries no privacy entitlements). `com.apple.security.personal-information.calendars` was consequently absent from the signed binary. The fix targets the main executable directly, producing a single correct plist for signing.

## [1.4.0] — 2026-04-05

### Added
- **Code syntax highlighting in overlay** — the overlay now detects Markdown code blocks (` ```lang ... ``` `) and inline code (`` `code` ``) in LLM responses and renders them with syntax coloring. Uses an Atom One Dark palette; supports Python, Swift, JavaScript/TypeScript, Go, Rust, C/C++, Bash, SQL, JSON, and a generic fallback for other languages. No external dependency — pure Swift token patterns via `NSRegularExpression`. Horizontal scroll inside code blocks preserves long lines without wrapping.
- **Polish dictation** — new toggle in Settings → Models. When on, raw dictation transcripts are passed through a quick LLM cleanup pass after recording stops: removes filler words (um, uh, like, you know, and language-native equivalents such as euh/beh/ähm/este), adds punctuation, and capitalizes sentences. Does not rephrase or change actual words. Falls back to the raw transcript silently on any LLM error. Requires a loaded LLM; no-ops when None is selected.
- **Action Mode: Notes** — say "take a note" or "note that…" to create a note in Apple Notes via AppleScript. A confirmation modal shows the title and body before anything is created.
- **Action Mode: Timer** — say "set a timer for 10 minutes" or "remind me in 30 seconds" to schedule a local macOS notification countdown. Uses `UNUserNotificationCenter`; prompts for notification permission on first use.
- **Action Mode: Email** — say "email John that I'll be late" to open a pre-filled compose window in your default mail client (Mail, Thunderbird, or any app set as default). If you speak a name without an email address, the compose window opens with an empty recipient field for you to fill in. Raw email addresses work directly. Never sends automatically — the user must press Send.
- **Gemma 4 E2B 5-bit** — added `mlx-community/gemma-4-e2b-5bit` (4.1 GB, Apache 2.0) to bundled model defaults. 140-language support, 128K context, thinking-block stripping in post-processing.
- **Overlay display mode** — when the focused element is not editable (PDF viewer, Finder, Terminal output), the LLM result from voice edit (Ctrl+Z) is shown in the overlay for 20 seconds instead of pasting into the void. Dictation and grammar fix always paste regardless. Falls back to paste if Accessibility detection is unavailable. The overlay auto-sizes its height to fit the response text (up to 10 lines); press Esc to dismiss early. Overlay shape uses a fixed-radius RoundedRectangle (17.5 pt) instead of Capsule, preventing the elliptical distortion for tall results.
- **LaTeX math rendering in overlay** — the overlay detects `$...$`, `$$...$$`, and `\[...\]` LaTeX delimiters and renders them with SwiftMath (SwiftMath 1.7+, native CoreText rendering, no WebKit). Mixed text + math responses render as an alternating VStack of plain text and math segments. `MathView.swift` is the sole file to change when swapping the LaTeX backend.
- **Settings: "Grammar Fix" renamed to "Tool Use"** — reflects the broader role of the Ctrl+A shortcut (Action Mode + grammar fix + display mode).

### Fixed
- **Document context for PDFs, Pages, and Word** — when Screen Context is set to Advanced, the LLM prompt now includes text from the broader document, not just what is visible on screen. For PDFs (Preview, PDF Expert, Skim, etc.) up to 5 pages are extracted anchored to the selected-text page. For Pages and Word documents the full body is extracted via AppleScript. Scanned image-only PDFs fall back to the existing OCR path. The character budget scales with the loaded model size (600 chars for LFM 1.2B → 2500 chars for Qwen3.5 9B).
- **Action Mode: notification permission dialog never appeared** — `UNUserNotificationCenter.requestAuthorization` is now called at app startup rather than the first time a timer action is triggered. LSUIElement (background) macOS apps do not display permission dialogs from within an action pipeline; requesting at startup with the app already registered in the notification center resolves this.
- **Action Mode: timer notifications silently dropped** — `UNUserNotificationCenter` on macOS delivers notifications that arrive while the app is "active" to its delegate. Without a delegate set, they are silently discarded. `NotificationDelegate` is now registered at startup and returns `.banner + .sound` so timer notifications always appear as banners regardless of app state.
- **Action Mode: email compose — empty subject field** — when the user did not explicitly state an email subject, the LLM returned an empty string. The action router prompt now instructs the model to always derive a concise subject from the body if none is stated. As a second safety net, `parseEmail` derives the subject from the first 8 words of the body when the LLM returns an empty string.
- **Action Mode: email body too short** — the router prompt now instructs the model to write a complete, naturally-written email body expanding on the user's intent, not just echo their words verbatim. `maxTokens` for the router increased from 250 → 500 to give the model headroom for a proper multi-sentence body.
- **Action Mode: email compose — "to" field removed** — the email action no longer tries to parse or resolve a recipient from speech. The compose window always opens with an empty "To" field for the user to fill in; the LLM only fills subject and body. This eliminates "Action Not Recognized" errors when no recipient was mentioned.
- **Gemma 4 E2B temporarily removed** — commented out from bundled model defaults and architecture detection until `mlx-swift-lm` adds support for the `Gemma4ForConditionalGeneration` (VLM) architecture.
- **Copy button in display-mode overlay** — Cmd+C cannot reach a non-activating panel (key events go to the frontmost app). A small clipboard icon now appears in the bottom-right corner of the overlay when a display-mode result is shown. One click copies the full text; the icon shows a checkmark for 1.5 s to confirm. Right-click → Copy still works as before.
- **Dictation overlay stays visible after manual stop** — pressing Ctrl+S to stop dictation now transitions to the "Transcribing…" state immediately, before the STT transcription completes. Previously the waveform dots stayed visible for up to 10 seconds while the final buffer was being transcribed.
- **Note creation fails for multi-line body** — the AppleScript used to create Notes now correctly escapes newline characters using AppleScript string concatenation (`" & return & "`). Previously any note body containing a newline would fail silently at the AppleScript level.
- **LaTeX inline math baseline misalignment** — inline math images now sit on the same text baseline as surrounding words. `MTMathListDisplay.descent` is the portion of rendered glyphs below the math baseline (fractions, subscripts); it is now applied as `.baselineOffset(-descent)` on each `Text(Image(...))` piece. Previously math floated above text by that amount.
- **LaTeX parser: `\(...\)` inline math support** — the segment parser now recognises `\(` … `\)` as an inline math delimiter in addition to `$...$`. Many LLMs default to `\(` for inline math (e.g. ChatGPT-style output); previously these were emitted as plain text.
- **OCR unblocks main thread** — `VNImageRequestHandler.perform` is a synchronous blocking call (50–500 ms). Although `runOCR` was marked `nonisolated`, calling it synchronously from `@MainActor` context still ran it on the main thread, freezing the UI before the "Generating…" state appeared. Both OCR call sites are now wrapped in `Task.detached(priority: .userInitiated)` so Vision runs off the main actor.
- **PDF anchor search skipped for large documents** — `PDFDocument.findString` scans the entire document sequentially; on PDFs over 50 pages this could add seconds to the context capture step. Anchor search is now skipped for PDFs with more than 50 pages (extraction starts at page 0 instead).
- **Auto-offload did not release WhisperKit / Qwen3-ASR STT memory** — `offloadAllModels()` guarded the `sttReady = false` assignment on `asrModels != nil`, which is only set for the FluidAudio backend. WhisperKit and mlxAudio hold their model weights inside the coordinator's `stt` service var, not in `asrModels`. The guard is now removed; `sttReady = false` fires unconditionally, which triggers the Combine sink that nils the coordinator's `stt` reference and releases WhisperKit/mlxAudio weights from memory.
- **Action Mode: Notes action hangs on first use** — `NoteService.createNote()` ran `NSAppleScript.executeAndReturnError` without a timeout. On first use, macOS presents an automation permission dialog ("Hitoku Draft wants to control Notes"); without a timeout the overlay appeared frozen until the user located and dismissed it. The AppleScript execution is now raced against a 30-second timeout via `withThrowingTaskGroup`. On timeout, an error is shown and the user can retry — on retry the permission is already granted so the dialog never appears again.
- **CodeHighlighter cache stopped filling after 100 entries** — the cache guard `if cache.count < 100` silently discarded new entries once full; subsequent code blocks were re-highlighted from scratch on every render. The cache now evicts all entries when the limit is reached (same pattern as `MathView.imageCache`) before inserting the new result.
- **LaTeX parser double-consumes `$$` opener as `$`** — the inline-math parser now uses `else if` so the single-dollar branch cannot fire on the same character position when a `$$` match fails.
- **Overlay display mode incorrectly triggered in Apple Mail and web-based editors** — `AXEditabilityDetector` now includes `AXWebArea` in the editable-role whitelist. Apple Mail's compose body (and other WebKit-based editors such as browser text areas and Notion) reports role `AXWebArea` to the Accessibility API. Previously this role was not in the whitelist and all attribute probes (`kAXSelectedTextAttribute`, `kAXInsertionPointLineNumberAttribute`) return failure for `AXWebArea`, causing voice-edit results to appear in the overlay instead of being pasted into the compose window.

## [1.3.0] — 2026-04-04

### Added
- **Whisper Base (English) and Whisper Tiny (English) STT models** — two new English-only speech recognition options using WhisperKit (CoreML/ANE). Whisper Base uses ~180 MB RAM; Whisper Tiny uses ~90 MB. Both run on Apple Neural Engine, leaving GPU free for the language model. Ideal for users with < 8 GB RAM or those who only need English transcription.
- **Action Mode (Ctrl+A, no selection)** — when no text is selected, Ctrl+A opens the overlay and listens for a voice command. Supports creating Calendar events and Reminders via EventKit. The LLM parses the intent and resolves relative dates ("tomorrow at 3pm", "next Monday"); a confirmation alert always appears before anything is written. Calendar events and reminders with or without due dates are both supported.
- **"None" LLM option** — First entry in the LLM picker disables the language model entirely. Voice edit pastes the raw STT transcript directly; grammar fix silently no-ops. Saves 2–7 GB RAM when transcription without editing is sufficient.
- **Auto-offload models** — New toggle in the Models tab releases both LLM and STT weights after 5 minutes of inactivity. Models reload from local cache on next use. Default: on.
- **Multi-turn follow-up commands** — after a successful voice edit, the last `(instruction, result)` pair is stored. If the next command has no selected text and arrives within 5 minutes, the prior result is injected as context so the LLM can refine without re-selecting. New selection always clears the context. STT-only mode (None LLM) is unaffected.

### Fixed
- **Mic stays on after dictation cancellation** — `ContinuousSession.stop()` is now called immediately when silence or cancellation is detected, before the transcription drain wait. Previously the microphone indicator could stay lit for up to 45 seconds after the user aborted dictation.
- **Qwen3.5 inline markdown in pasted text** — Qwen3.5 output no longer includes `**bold**` or `*italic*` markers. Stripping is scoped to Qwen3.5 only; other model families are unaffected.
- **Action Mode: Calendar/Reminders permission dialog never appeared** — added `com.apple.security.personal-information.calendars` entitlement. With Hardened Runtime enabled, macOS silently blocks EventKit requests without this entitlement even for non-sandboxed apps; no dialog was shown and no TCC entry was created.
- **Action Mode: EventKit async bridging** — replaced `withCheckedContinuation` callback wrappers with native `async throws` EventKit APIs (`requestWriteOnlyAccessToEvents()`, `requestAccess(to:)`), which work correctly in Swift concurrency contexts.
- **Grammar fix triggered by Finder file selection** — `captureSelectedText()` now returns empty string when the clipboard contains file URL types (`public.file-url`) after Cmd+C. Previously, selecting a file in Finder and pressing Ctrl+A would pass the filename to grammar fix instead of routing to Action Mode.
- **Removed model no longer silently drops user to No LLM** — `ModelManager` now falls back to `smartDefault` when the saved model path is not found in the current bundled list (e.g. after a model is removed in an update). Previously it fell back to `noLLM`, leaving users in STT-only mode without warning.

### Changed
- **STT smart default now RAM-based** — ≥16 GB machines default to Parakeet TDT v3 (best multilingual quality, 0.6 GB, ANE); ≥8 GB machines default to Whisper Base (180 MB, English); <8 GB machines default to Whisper Tiny (90 MB, English).
- **Model list pruned and sorted** — removed Granite 4 Micro 4-bit (1.8 GB) and Qwen3 8B 4-bit (4.6 GB) from bundled defaults. Remaining five models now appear in ascending size order: LFM2.5 1.2B 4-bit (676 MB) → LFM2.5 1.2B 8-bit (1.2 GB) → Qwen3.5 4B 4-bit (2.5 GB) → Granite 4 Micro 8-bit (3.4 GB) → Qwen3.5 9B 4-bit (6.5 GB). LLM smart default for <8 GB RAM now selects LFM2.5 1.2B 8-bit.

### Developer
- **VAD data race eliminated** — `VoiceActivityDetector` converted from `@unchecked Sendable` class to `actor`. `streamState` (the LSTM's hidden/cell state) is now actor-isolated: concurrent `Task { await vad.feedSamples() }` calls queue at the actor boundary and execute serially. `speechDetected`, `silenceAfterSpeech`, `speechProbability` are `nonisolated let` so the synchronous RT tap callback can read them without `await`.
- **Per-token regex eliminated from streaming overlay** — `streamingLLMText` now publishes raw token chunks during generation; `family.postProcess()` (which runs up to 4 NSRegularExpression passes) runs only once on the final accumulated string before paste. No change to pasted output quality.
- **STT layer fully modularised** — `STTService.swift` and `TranscriptionPipeline.swift` have zero framework imports. New backend-agnostic `STTEvent` enum replaces `TranscriptionEvent` at the protocol boundary. Private `MLXStreamingSession` adapter in `MLXAudioSTTService.swift` converts events; `WhisperKitSTTService` is a clean separate file. Adding a fourth STT backend requires no changes outside its own file.
- **Streaming LLM output** — `LLMService` protocol gains `generateStream()` returning `AsyncThrowingStream<String, Error>`; `MLXLLMService` implements it. `ConversationCoordinator` publishes `streamingLLMText` (accumulated token stream). Post-processing (`OutputCleaner`, `stripEcho`) runs on the final accumulated string before paste. Grammar fix continues to use batch `generate()`.
- **Lazy LLM warmup** — LLM loads at `setup()` as a non-blocking background task; app opens instantly and Settings are fully accessible without a loading spinner.
- **Prompt templates externalized to JSON** — all system prompts and edit/draft templates moved from hardcoded Swift to `PromptsConfig.json`. Power users can override via `~/Library/Application Support/HitokuDraft/prompts.json`. Templates use `{{text}}`, `{{instruction}}`, `{{langRule}}`, `{{contextBlock}}` placeholder tokens. 3-level fallback chain: user override → bundled JSON → hardcoded Swift constants.
- **AppDomainHint refactored — data-driven config** — all hard-coded browsers, app-name rules, and hint texts moved to `AppDomainConfig.json`. New categories and apps can be added without any Swift changes. `AppCategory` enum removed; `AppDomainHint` is now a thin JSON loader with the same public API.
- **Architecture refactor — ConversationCoordinator** — `DictationOverlayPanel` decoupled (Combine subscriptions replace 25 imperative call sites); `runStreamingTranscription` extracted to `TranscriptionPipeline.swift`; `activateLLM()` helper deduplicates LLM load/warmup/idle try-catch; `SilenceDetectionState` struct deduplicates ~80 lines of VAD+RMS tap logic; `contextAwareMode` changed from computed property to `@Published`; `LockedString` replaces `nonisolated(unsafe)` in streaming path; dead code `ModelManager.loadAll()` removed.
- **Settings — Models tab polish** — Converted from `Form {}` to `Grid {}` so all input controls share identical horizontal left-edge alignment. Auto-offload description inline to the right of the toggle. Add button co-located with Model Path text field. Browse button uses conditional visibility instead of hidden ZStack.
- **Settings — General tab polish** — Voice Edit, Grammar Fix, Dictation keyboard shortcut recorders left-edge aligned; `−6 pt` leading offset compensates for the NSViewRepresentable/NSButton internal visual inset.
- **Settings — STT model picker** — Removed "(streaming)" suffix from Qwen3-ASR descriptions. Whisper models show "(English only)" and "lower accuracy". Language restriction badge removed from picker rows.
- **Settings — Theme tab polish** — Subtitle caption added to "Show dictation text" toggle. Vertical spacing improved. Theme tab window height 430 → 473 pt.

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
