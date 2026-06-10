# Changelog

All notable changes to Hitoku Draft are documented in this file.

## [Unreleased]

### Changed
- **Internal architecture cleanup.** The app's central orchestration code was split
  into focused modules (overlay result display, model loading/switching), with no
  user-visible behavior change. Improves reliability of future updates.
- **More efficient UI updates.** The app's interface state management was modernized
  so views refresh only when something they actually display changes, instead of on
  every internal state change. Reduces redundant redraw work across the menu bar,
  Settings window, overlay, and Transcribe window.
- **Smoother streaming display.** The overlay now does much less repeated work while
  an answer streams in or is read aloud: text is parsed for math/code once per change
  instead of on every redraw, read-aloud progress is computed incrementally, and
  syntax-highlighting patterns are compiled once. Long answers and code blocks render
  noticeably smoother, and read-aloud progress no longer jumps backwards when the
  same sentence appears twice in an answer.

### Fixed
- **Memory and stability hardening.** Cancelling an AI generation mid-stream now
  releases the model promptly instead of holding it until the generation would have
  finished on its own — reduces memory pressure when switching models or retrying
  quickly on 8 GB machines. Also fixed several internal thread-safety issues in the
  model routing and logging paths, and reduced needless allocations in the overlay's
  audio-level animation.

## [1.6.6] - 2026-06-07

### Fixed
- **Help tab layout.** The "How to use" content was clipped at the top in some window
  sizes. Removed the redundant heading so all rows and the footer fit cleanly.

## [1.6.5] - 2026-06-07

### Added
- **Formatted overlay answers.** Answers shown in the overlay now render inline
  Markdown: **bold**, *italic*, `inline code`, and ~~strikethrough~~. This applies to
  the final displayed answer; text stays plain while it is still being generated or read
  aloud. (Headings and bullet lists are not styled yet.)
- **Context logging in interaction logs.** Each saved Voice Edit log now records
  exactly what the model was given before it answered: the screen-context text block
  (what it actually read), the context source (accessibility / ocr / title / none),
  the context mode, whether a screenshot was sent, and the model name plus backend.
  This makes a log falsifiable: you can see whether a wrong answer came from a bad
  screen read, the wrong model, or the model itself.
- **Latency split in interaction logs.** Voice Edit logs now also record per-phase
  timings in milliseconds: context capture, final speech transcription, time to first
  token, full model generation, insertion, and total. Shows exactly where the time went.
- **Transcribe files with the AI model (Gemma).** The Transcribe window can now use
  Gemma instead of a dedicated speech model, which is better for mixed and many
  languages (slower). Selectable when the chosen LLM supports audio. New
  `LLMTranscriptionSTT` wraps the LLM as a transcriber so the chunked flow is unchanged.
- **Help tab in Settings.** A "How to use" tab explains the main actions (dictate,
  edit/ask with voice, tool use, transcribe files, screen awareness, models, privacy).
  Shortcuts are read live from the user's bindings, so it stays correct after rebinding.
- **Gemma 4 12B built-in model.** Added as a featured LiteRT option (text + audio, no
  vision encoder in this build; ~10 GB RAM). Descriptions localized in all four languages.
- **Custom LiteRT-LM models from HuggingFace.** The Settings "Model Path" field now
  accepts `litert-community/…` repos (e.g. `litert-community/gemma-4-12B-it-litert-lm`),
  not just `mlx-community/…`. A repo path containing "litert" is auto-configured for the
  LiteRT backend, and the specific `.litertlm` filename is resolved from the HuggingFace
  API at download time (preferring the native build over the `-web` variant). New
  `ModelManager.resolveLiteRTFilename(repo:)`; `downloadAndAddCustomModel` resolves it
  before loading and errors clearly if the repo has no `.litertlm`.

### Changed
- **Voice commands (Ctrl+Z / Ctrl+A) now route as text when a speech model is loaded.**
  Previously, with a Gemma model, the command was sent as raw audio (audio-direct). Now
  the speech model transcribes the command and Gemma receives explicit text, so it can
  never echo or paste the screen. Audio-direct remains only as the no-STT fallback, where
  a single call includes a system-prompt gate that outputs NOOP (and does nothing) if no
  clear instruction was spoken. See `docs/SPEECH_AND_AI_DESIGN.md`.
- **In-app "What's New" refreshed for this release.** The upgrade screen now lists the
  current features (file transcription, Help guide, model choices, formatted answers, web
  sources, on-screen answer reliability) instead of stale older highlights.

### Fixed
- **Asking with no text field selected no longer loses the answer.** On the desktop or in
  Finder, the focus detector could mistake a non-text container for a text cursor and try
  to paste the answer into nothing, so it vanished. It now correctly recognizes there is no
  cursor and shows the answer in the overlay instead. The shown answer stays put and
  auto-closes ~40 seconds after you stop interacting with it (hovering or focusing the
  overlay pauses that countdown); Esc dismisses it anytime.
- **Gemma 4 12B failed to start with "Failed to create conversation."** The 12B LiteRT
  build ships without a vision encoder (audio + text only), but the app requested a vision
  backend, which the engine rejected with "TF_LITE_VISION_ENCODER not found". Vision is now
  requested only for models that actually ship a vision encoder; 12B runs as audio + text.
  Underlying LiteRT errors are also surfaced now instead of the generic message.
- **Web search and other Gemma actions could hang on "Generating" indefinitely.** The
  LiteRT backend ignored the per-request token limit (the SDK only has an engine-wide
  context cap), so a model that did not emit a stop token kept generating toward the full
  context window, which looked like a multi-minute freeze. Output is now capped at the
  requested limit and the conversation is cancelled when it is reached. Affects all Gemma
  generation paths.
- **Web search now always shows its sources** (titled list with host), so the answer is
  verifiable.
- **Voice Edit on the desktop (no app focused) closed instead of showing the answer.**
  With nothing focused, the editability check failed open to "paste", so the result was
  pasted into nowhere and the overlay closed. Now, when accessibility is granted and
  there is no focused element, the answer is shown in the overlay as expected.
- **Help tab shortcuts now update live** when you rebind them in the General tab.
- **Voice Edit could echo and paste your screen on an unclear utterance.** In
  audio-direct mode, a noise or mumble that wasn't a real command let the model
  describe the screenshot and paste that. Now the command is gated: a transcript with
  fewer than two words (speech-model path) or a NOOP response (no-STT path) does nothing.
- **Clearer "None" speech-model description.** Reworded to explain that voice commands
  use an audio-capable LLM (Gemma 4) and dictation loads a speech model on demand.

## [1.6.4] — 2026-06-04

### Added
- **File transcription from the menu bar.** New "Transcribe File…" menu item opens
  a window where you drag-and-drop or browse to audio/video files, transcribe them
  with the currently-loaded STT model, watch a live percentage, and Copy/Save the
  text (`.txt`). Esc closes the window.
  - **Multiple files**: add a batch, transcribe them all sequentially, and select
    any file in the list to view its transcript. Per-file status + progress.
  - **Edit with Voice**: a bottom bar lets the loaded LLM rewrite the selected
    transcript from a typed or dictated command ("bullet points", "fix punctuation",
    "translate to French"). Backed by new `ConversationCoordinator.editText(_:instruction:)`
    and `dictateCommand()`; window widened ~20% (460→552) for the editor. New `AudioFileDecoder` (any audio → 16 kHz
  mono via `AVAudioConverter`, block-streamed for long files), `FileTranscriptionModel`
  (30 s chunking, per-chunk error tolerance, live result), `FileTranscriptionView`,
  and `TranscriptionWindowController`. Reuses the existing `STTService` path — no
  changes to the dictation pipeline.
  - _Limitations (v1):_ audio files only (not video tracks), plain-text output (no
    timestamps/SRT), fixed 30 s chunk boundaries; UI strings English-only pending
    localization.

### Fixed
- **Voice Edit (Ctrl+Z) showed no transcript with Gemma/LiteRT.** In audio-direct
  mode the model hears the audio and STT was skipped entirely, so the user never saw
  their words. A display-only STT is now loaded during recording so the live
  transcript shows (the answer still comes from audio-direct — no quality change).
- **"Edit with Voice" failed on long transcripts** with a raw native error
  ("INVALID_ARGUMENT: Input token ids are too long"). Raised the LiteRT context window
  4096 → 8192 (Gemma 4 supports far more; modest KV-cache cost), and map the
  over-limit case to a readable message suggesting a shorter file or a length-reducing
  edit.
- **Polish dictation description was truncated** ("…Requires loaded L…"). The Settings
  row now wraps to a second line (`.fixedSize`) — language-agnostic, so it reads in
  full in all locales.
- **Voice Edit (Ctrl+Z) answer behaved differently per app — pasted in Safari/VSCode,
  displayed in Firefox.** The detector treated any focused `AXWebArea` as editable, so
  a read-only web *page* counted as a paste target and the answer was pasted (overlay
  closed) instead of shown. Detection is now caret-based (`AXSelectedTextRange`): if
  there's a real text insertion point, paste there; otherwise show in the overlay.
  Deterministic and app-independent — no intent guessing.
- **File transcription failed to open MP3s ("Could not open the audio file").**
  Replaced the `AVAudioFile`-based decoder (unreliable for compressed formats) with
  `AVAssetReader`, which robustly decodes MP3/M4A/AAC/WAV/AIFF/FLAC (and video audio
  tracks) and resamples to 16 kHz mono itself.
- **File transcription reported "no model" even with STT active.** ASR models had
  been offloaded from RAM; `makeSttServiceForFile()` now reloads the currently-selected
  STT from local cache on demand (no download). The "pick a model" message only shows
  when STT is set to None.
- **Can't scroll the overlay during/after generation.** The overlay panel is
  borderless, so `canBecomeKey` was `false` — button clicks worked but scroll
  and text selection didn't. Introduced `InteractiveOverlayPanel` (NSPanel
  subclass overriding `canBecomeKey`); it stays `.nonactivatingPanel`, so the
  user's frontmost app keeps focus for pasting. Also set `acceptsMouseMovedEvents`
  so hover tracking fires.
- **Display-mode answer (Ctrl+Z "explain") closed itself while being read.** The
  hard 30s auto-dismiss fired even mid-read. The countdown is now a separate,
  restartable timer (`displayDismissTask`) that **pauses while the cursor is over
  the overlay** (`.onHover` → `keepDisplayResultAlive`) and resumes on exit;
  base timeout raised 30s → 45s. The three duplicated inline timers were unified
  into `scheduleDisplayAutoDismiss(after:)`.

### Added
- **Stop TTS playback from the overlay.** The Read Aloud speaker button now
  toggles to a Stop button (`stop.fill`) while TTS is playing — tapping it
  silences playback immediately while keeping the text on screen (the 30s
  auto-dismiss restarts). Previously, once Read Aloud started there was no way
  to stop it short of Esc (which also dismissed the overlay). New coordinator
  method `stopReadAloud()`; `OverlayActionButtons` gains an `isSpeaking` toggle.

### Changed
- **LiteRT now uses Google's official LiteRT-LM Swift SDK (v0.13.1).** Replaced
  the hand-rolled `dlopen`/`dlsym` C bridge with the SwiftPM `LiteRTLM` package.
  The backend (`LiteRTInferenceBackend`) is rewritten against the SDK's actor-
  isolated `Engine` + `Conversation` API: native `AsyncThrowingStream` streaming,
  `Content.text/.imageData/.audioData` for multimodal input, and `Engine`-managed
  lifecycle. The `InferenceBackend` protocol seam is unchanged, so the rest of
  the app (RoutedLLMService, ModelManager) is untouched.

### Removed
- `CLiteRTEngine` system-library target (`engine.h` + module map).
- `LiteRTEngine.swift` — the `dlopen` loader and 17 hand-typed C function pointers.
- `HitokuInference/Libraries/macos_arm64/` and the "Embed LiteRT Dylibs" build
  phase. The official SDK's `CLiteRTLM_mac.xcframework` is embedded by SwiftPM
  (–98 MB of manually-bundled dylibs).
- Manual JSON message building, temp-file media passing, and the `Unmanaged`
  `StreamContext` retain/release dance — all subsumed by the SDK.

### Notes
- Package pinned by revision (`a0afb5a`, v0.13.1 tag): the SDK's `LiteRTLM`
  target uses `.unsafeFlags(-all_load)`, which SwiftPM forbids for versioned deps.
- Resolution requires `GIT_LFS_SKIP_SMUDGE=1` (the SDK repo's `prebuilt/` LFS
  blobs are unrelated to the macOS xcframework and one is missing upstream).
- **Pending:** runtime verification of Gemma E4B generation + Metal memory on the
  new engine (old vendored dylibs hit a 10× WebGPU allocation; see KNOWN_ISSUES).

## [1.6.3] — 2026-04-12

### Improved
- **TTS pre-warm at launch** — TTS provider (Kokoro/PocketTTS) is now initialized at app startup in a background task. The first "Read Aloud" press is instant instead of waiting 1-2s for CoreML compilation.
- **Fast "Read Aloud"** — Switched from single-utterance synthesis (waited for entire text) to sentence-by-sentence streaming with larger chunks for natural prosody.
- **Overlay scroll during generation** — Text no longer auto-scrolls; user can read freely. Auto-scrolls only during TTS to follow the highlighted segment. Scroll indicators now visible.
- **TTS settings always visible** — TTS engine, voice, and speed pickers are always shown in Settings (previously hidden behind toggle). Toggle now only controls auto-readback.
- **TTS acronym pronunciation** — Acronyms like LLM, SAE, GPU are now spelled out letter-by-letter for natural TTS output.
- **Speaking state keeps action buttons** — Copy and Read Aloud buttons remain visible during TTS playback alongside the progress bar.

### Fixed
- **Voice edit not pasting in Apple Mail** — Apple Mail's WebKit compose field reports `AXWebArea` without settable text range. Editability detector now treats all focused `AXWebArea` elements as editable, fixing paste in Mail, Gmail, and Notion.
- **Editability captured too late** — Editability check now runs at Ctrl+Z press time, before model loading or overlay display can shift AX focus.
- **Overlay disappearing during TTS** — The 30-second auto-dismiss timer now waits for TTS playback to finish before counting down.
- **TTS progress bar stuck** — Progress calculation now uses character position instead of sentence counting, giving accurate 0→1 progress.
- **Vision toggle race condition** — "Allow vision" now routes through `coordinator.switchModel()` for proper state management and task cancellation.

## [1.6.1] — 2026-04-12

### Fixed
- **Memory spike when toggling "Allow vision" with Gemma 4** — Toggling the checkbox reloaded the LiteRT model unnecessarily, creating a second engine before freeing the first (12+ GB observed). LiteRT models have built-in vision and no longer reload on vision toggle.
- **Missing translations** — Tools tab, model descriptions, and "Polish dictation" label/description were hardcoded English or missing from Spanish/French/Italian. ~30 new localization keys added per language.
- **TTS not pronouncing numbers** — Number-to-words conversion only ran in the streaming path. Full-text speak and "Read Aloud" button now also convert numbers ("42" → "forty-two").
- **What's New window** — Updated content for v1.6.0 features.
- **Overlay pill sizing** — Removed 40pt of dead space in listening/generating states.
- **Overlay on wrong screen** — `NSScreen.main` now captured at hotkey-press time instead of lazily at panel creation.

## [1.6.0] — 2026-04-12

### Added
- **TTS thinking block filter** — Gemma 4 thinking blocks (`<|channel>thought...<channel|>`) no longer read aloud. `ThinkingBlockFilter` stateful filter strips thinking content from the TTS streaming path while preserving it in the overlay.
- **Separate STT auto-offload timer** — Independent 2-minute timer for STT models. When Gemma loads STT on-demand for dictation, STT (~460 MB) frees independently from the 5-minute LLM timer.
- **HitokuInference framework** — Independent Swift Package (`HitokuInference/`) with `InferenceBackend` protocol, `InferenceRouter` for multi-backend dispatch, and `InferenceRequest` multimodal value type. Backends conform to the protocol; callers depend only on abstractions.
- **MLXBackend** — Wraps existing MLXLLM/MLXVLM `ModelContainer` behind `InferenceBackend`. Drop-in replacement for direct `MLXLLMService` usage.
- **LiteRTBackend** — Google LiteRT-LM integration via dlopen/dlsym C bridge. Supports Gemma 4 E2B with native audio + vision + text in a single model. GPU (Metal/WebGPU) for text generation, CPU for audio encoder.
- **Gemma 4 E2B model** — Selectable in model picker. 2.6 GB, ~100 tok/s GPU decode. Understands voice commands natively with built-in audio + vision.
- **Gemma 4 E4B model** — Larger LiteRT multimodal model (3.7 GB) for higher quality output.
- **Audio-direct voice edit** — When LiteRT backend is active, voice instructions are sent as raw WAV audio directly to the model. No separate STT step needed.
- **Audio-direct action mode** — Ctrl+A works with LiteRT: Gemma transcribes audio natively before routing to ActionRouter.
- **RoutedLLMService adapter** — Bridges app-level `LLMService` protocol to `InferenceRouter`. All existing callers (ConversationCoordinator, ActionCoordinator, DictationPolisher) work unchanged.
- **AudioEncoder utility** — Converts Float32 PCM samples to WAV format for LiteRT audio input.
- **Smart STT management** — STT skipped on launch when Gemma is active. Loaded on-demand for dictation (stays in memory until auto-offload). Settings shows "Built into the LLM model" for Active STT.
- **"None" STT option** — Users who only use Gemma can select "None" in the STT picker to avoid loading any speech model.
- **Gemma repetition protection** — Temperature floor (0.5), higher top_p (0.95), 20-chunk loop detection, tool-use disabled.
- **Background LLM loading** — Voice edit loads LLM without changing app state, so recording isn't interrupted.

### Fixed
- **LiteRT crash on repeated Ctrl+Z** — Five bugs in `LiteRTInferenceBackend`: (1) messageCStr freed inside callback while C library still referenced it, (2) StreamContext double-released on repetition detection, (3) cancelGeneration() leaked C conversation object, (4) no thread synchronization on mutable state, (5) no onTermination handler for stream cancellation.
- **Voice edit empty/short output** — Qwen 3.5 and Gemma 4 switched from `conciseDraft` to standard `draft` template (with `Request:` label) and standard system prompt (no more "Be brief"). Removed post-hoc stripEcho (caused false positives). Disabled TTS during voice edit — PocketTTS GPU contention caused 0-token LLM output.
- **Gemma 4 output too short** — Bumped token limits from 400→800 (draft) and 500→1000 (edit) to account for thinking block overhead.
- **ActionConfirmationPanel crash** — NSAlert.runModal() now dispatched to MainActor (was crashing from background thread).
- **"No speech detected" with Gemma** — Audio-direct path now polls for VAD silence detection instead of falling through immediately.
- **Model memory leak** — Old backends properly freed on background thread when switching models.

### Changed
- **Streamlined model picker** — Removed LFM2.5 and Granite 4 Micro from bundled defaults. Models sorted by size. Users can still add any model via Custom Source.
- **Voice readback** — TTS in display/non-editable mode (e.g. reading a PDF with Ctrl+Z). Two engines: Kokoro (multi-voice, speed control) and PocketTTS (flow-matching). Streaming TTS with prefetch synthesis, adaptive chunking, and segment highlighting in the overlay.
- **Browser context** — Full-page text extraction from Safari, Chrome, Arc, Brave, and Edge via AppleScript JavaScript. Data-driven browser registry for easy extensibility.
- **Vision Language Model support** — Qwen3.5 models load via MLXVLM and can see window screenshots in Advanced context mode. The LLM describes images, charts, and UI on screen.
- **Web search** — LLM can search the web during generation via DuckDuckGo (no API key). Toggle "Allow internet access" in Settings → General. Also includes URL fetching for reading articles. Ctrl+A web search with LLM-summarized results and source citations.
- **Calendar tools** — Query calendar via voice: "Am I free tomorrow?", "What's on my calendar today?". Lists events, finds free time, checks availability across all calendars. Works via both Ctrl+A and Ctrl+Z tool use.
- **KV cache quantization** — 4-bit KV cache enabled for all generation paths (text + VLM). ~3x context window extension with near-zero quality impact.
- **TTS number pronunciation** — Numbers automatically converted to words before TTS synthesis ("11" → "eleven", "3.14" → "three point one four").
- **TTS auto language detection** — Kokoro automatically switches voice to match the output language (English, Italian, French, Spanish, Japanese, etc.) using NLLanguageRecognizer.
- **Chat data models** — ChatMessage, Conversation, and ChatStore scaffolded for future persistent conversation history.

### Fixed
- **Ctrl+S dictation overlay missing** — `state = .dictating("")` was accidentally removed during the overlay refactor. Without this initial transition, the overlay never appeared, Ctrl+S toggle didn't stop dictation, and live transcription text never updated.
- **Overlay stuck at "Generating..." after paste** — `OverlayViewModel` Combine sinks were firing on `@Published` `willSet` (before property update), causing `deriveState()` to always read the previous state. Re-added `.receive(on: RunLoop.main)` to defer until properties are updated.
- **Ctrl+S overlay lag (~300ms)** — Same `@Published` timing bug. The initial `.dictating("")` state was missed, overlay only appeared on first streaming text update.
- **Fullscreen apps not captured** — Window-based ScreenCaptureKit capture fails for fullscreen apps in other Spaces. Added display-based fallback that captures the full screen when the target window isn't found.
- **Overlay sliding between screens on multi-monitor** — Panel was kept alive across hide/show cycles, causing visible movement to the new screen. Now destroyed on hide and recreated fresh on the active screen.
- **Gemma 4 quality (terse, repetitive, hallucinations)** — Switched draft prompt from `conciseDraft` to explicit `draft` template. Lowered temperature 0.6→0.5 and top_p 0.95→0.9 for tighter, more deterministic output. Note: LiteRT C API has no repetition penalty field — the ModelFamily value is silently ignored.
- **Overlay pill too tall in listening/generating states** — Panel unconditionally reserved 40pt for action buttons/progress bar. Now conditional: only `.speaking` and `.done` get the extra height.
- **Overlay on wrong screen in multi-monitor** — `NSScreen.main` was read lazily at panel creation (after async setup could shift focus). Now captured at hotkey-press time and passed to the panel.
- **Safari treated as editable** — AXWebArea role now has a refinement check (settable text range) to distinguish read-only articles from web editors like Gmail/Notion.
- **Esc key system alert sound** — CGEventTap suppresses the Esc key globally when the display overlay is visible.
- **PocketTTS voice compatibility** — Filtered to voices with 125-frame prompt length (the only format FluidAudio supports).
- **Menu bar gap** — Removed extra spacing between status text and Preferences.
- **Dictation overlay conflict** — Starting dictation now clears any existing display-mode overlay.
- **About window** — Title is plain text, copyright line is the clickable link.

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
