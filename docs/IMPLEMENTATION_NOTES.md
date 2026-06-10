# VoiceEditor — Implementation Notes

## Build Log

### Phase 1: Project Setup

**Decisions:**
- Using `swift-tools-version: 5.10` (not 6.0) to avoid strict concurrency enforcement while still being modern. FluidAudio uses 6.0 but that's per-module — consumers don't need to match.
- SPM executable target (not Xcode project). User opens Package.swift in Xcode to build. Info.plist and entitlements are reference files to configure in Xcode build settings.
- Local dependencies referenced as relative paths: `FluidAudio/` and `mlx-swift-lm/` are siblings to the `VoiceEditor/` source directory inside the project root.
- Added `mlx-swift` as direct dependency to access `MLX.GPU` for cache limit setting.

**SPM dependency versions:**
- FluidAudio: local (requires swift-transformers >=1.1.6)
- mlx-swift-lm: local (requires swift-transformers >=1.1.9, mlx-swift >=0.30.6)
- mlx-swift: .upToNextMinor(from: "0.30.6") — matches mlx-swift-lm's requirement
- KeyboardShortcuts: from "2.0.0"
- swift-transformers version conflict resolved automatically — 1.1.9+ governs (from mlx-swift-lm)

**Files created:**
- `Package.swift` — SPM package definition
- `VoiceEditor/Info.plist` — LSUIElement=true (no Dock icon)
- `VoiceEditor/VoiceEditor.entitlements` — increased-memory-limit + network.client, NO sandbox

---

### Phase 2: Core Services

**PermissionsCoordinator:**
- `@MainActor ObservableObject` with polling timer (2s interval) to detect permission grants
- `AXIsProcessTrusted()` for accessibility, `AVCaptureDevice.authorizationStatus` for mic
- `requestAccessibility()` uses `kAXTrustedCheckOptionPrompt` to show system dialog

**TextCaptureService:**
- `@MainActor` since NSPasteboard and CGEvent are main-thread APIs
- Clipboard snapshot copies raw `Data` blobs per pasteboard type (not just strings)
- Simulates Cmd+C/V via `CGEvent` with keyCode 0x08 (c) and 0x09 (v)
- Uses `NSPasteboard.general.changeCount` to verify copy succeeded
- Methods are `async` to use `Task.sleep` instead of `Thread.sleep` for delays

**AudioCaptureService:**
- `AVAudioEngine` with `installTap` on input node, 100ms buffer chunks
- RMS via `vDSP_measqv` (Accelerate framework) — returns mean of squares, we sqrt for RMS
- Silence detection: threshold 0.015, duration limit 1.5s
- Max recording duration 30s to prevent stuck state
- Bridges audio tap to async context via `AsyncStream` with `onTermination` for cleanup
- Tap installed in AsyncStream builder (runs synchronously at creation), engine started after
- Captures threshold values (not self) in closure to avoid retain issues

---

### Phase 3: ML Services

**STTService protocol:** `func transcribe(audioURL:) async throws -> String`
**LLMService protocol:** `func generate(prompt:maxTokens:) async throws -> String` + `warmup()`

**FluidAudioSTT:**
- Wraps `AsrManager` with `.default` config
- `AsrModels.downloadAndLoad(version: .v3)` for Parakeet CoreML models (runs on ANE)
- `@unchecked Sendable` because AsrManager is thread-safe internally but not marked Sendable
- Transcribe via `manager.transcribe(url, source: .microphone)` → `.text`

**AppleSTT (fallback):**
- `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- `SFSpeechURLRecognitionRequest` → `recognitionTask` wrapped in `withCheckedThrowingContinuation`
- Zero-download fallback available immediately while FluidAudio models download

**MLXLLMService:**
- Wraps `ModelContainer` (actor, already Sendable) from mlx-swift-lm
- Custom `ModelConfiguration(id: "mlx-community/gemma-3-1b-it-8bit", extraEOSTokens: ["<end_of_turn>"])`
- Generation: `UserInput` → `prepare()` → `LMInput` → `generate()` → `AsyncStream<Generation>`
- Temperature 0.0 (greedy/deterministic) for consistent editing
- Accumulates `.chunk` values from stream into result string
- Properly Sendable (only holds `let modelContainer: ModelContainer`)

**ModelManager:**
- `@MainActor ObservableObject` with `@Published` progress properties
- `loadAll()` downloads LLM + STT sequentially (both async, don't block MainActor)
- LLM: `LLMModelFactory.shared.loadContainer(configuration:progressHandler:)`
- STT: `AsrModels.downloadAndLoad(version: .v3)`
- Progress callback updates `llmProgress` via `Task { @MainActor in }`

---

### Phase 4: Orchestration

**ConversationCoordinator:**
- `@MainActor ObservableObject`, single orchestration center
- Owns all services, `AppState`, permissions, model manager
- `setup()`: init fallback STT → download models → create services → warmup → idle
- `handleVoiceEdit()`: save clipboard → Cmd+C → record → STT → detect mode → LLM → clean → paste → restore
- `handleGrammarFix()`: save clipboard → Cmd+C → detect language → LLM grammar prompt → clean → paste → restore
- Falls back to AppleSTT if FluidAudio not ready
- Audio cues: NSSound "Tink" on recording start, "Pop" on paste
- Error: restore clipboard, show error 3s, auto-reset to idle
- `hasCompletedOnboarding` persisted in UserDefaults

**Prompts:** System instructions merged into user message (Gemma doesn't support system role well)
**OutputCleaner:** Strips preamble ("sure", "certainly", etc.), code fences, trailing notes
**DraftDetector:** First-3-word triggers + content signals anywhere in command
**LanguageDetector:** `NLLanguageRecognizer` → 2-letter code, default "en"
**Instructions:** Localized grammar-fix prompts for en, it, fr, de

---

### Phase 5: UI

**MenuBarView:** Reflects AppState with appropriate icons/text, settings link, quit button
**SettingsView:** KeyboardShortcuts.Recorder for both hotkeys, permission status, model info
**OnboardingView:** First-launch flow with permission checklist + model download + "Get Started"
**DownloadProgressView:** Reusable ProgressView with percentage

---

### Phase 6: Integration

**KeyboardShortcuts+Names:** `.voiceEdit` = Ctrl+Shift+A, `.grammarFix` = Ctrl+Shift+Z
**HotkeyManager:** Registers `onKeyUp` handlers that call coordinator methods

---

## Key API Patterns Used

### FluidAudio
```
AsrModels.downloadAndLoad(version: .v3) → AsrModels
AsrManager(config: .default) → initialize(models:) → transcribe(url, source: .microphone) → ASRResult.text
```

### mlx-swift-lm
```
ModelConfiguration(id: "...", extraEOSTokens: [...])
LLMModelFactory.shared.loadContainer(configuration:progressHandler:) → ModelContainer
UserInput(prompt: .chat([.user("...")])) → modelContainer.prepare(input:) → LMInput
modelContainer.generate(input:parameters:) → AsyncStream<Generation> → .chunk(String)
```

### KeyboardShortcuts
```
KeyboardShortcuts.Name("voiceEdit", default: .init(.a, modifiers: [.control, .shift]))
KeyboardShortcuts.onKeyUp(for: .voiceEdit) { handler }
KeyboardShortcuts.Recorder("Voice Edit:", name: .voiceEdit)
```

### MLX GPU Cache
```
import MLX
Memory.cacheLimit = 20 * 1024 * 1024  // NOT GPU.set(cacheLimit:) which is deprecated
```

---

## 2026-06-09 — Concurrency & Memory-Safety Hardening (audit batch 1)

Five fixes from the full-codebase audit (architecture / memory / concurrency / performance / modernization). Build verified clean.

1. **`MLXLLMService.generateStream` (both overloads)** — `Task { [self] }` kept the service + `ModelContainer` alive after a consumer cancelled the stream (double-model residency during model switch). Now captures `[modelContainer, family, systemPrompt]` by value, checks `Task.checkCancellation()` per chunk, and wires `continuation.onTermination = { task.cancel() }` so dropping the stream cancels generation.
2. **`InferenceRouter`** — was `@unchecked Sendable` with an unsynchronized `backends` dictionary + `preferred` var, mutated on MainActor and read from detached/generation tasks. All state access now goes through an `NSLock`; backend calls (`unload`, `loadModel`, `generate`) happen on a snapshot outside the lock to avoid holding it across slow work.
3. **`Task.detached` logging blocks** (dictation, grammar fix, STT-only voice edit) — read `modelManager.selectedModel.name` and `NSWorkspace.shared.frontmostApplication` (both MainActor-bound) off-actor. Values are now captured into locals before detaching, matching the voice-edit path's existing pattern. These would be compile errors under Swift 6 strict concurrency.
4. **`OverlayViewModel.startPolling`** — 30 Hz timer allocated a throwaway `Task { @MainActor }` per tick; the timer already fires on the main run loop, so it now uses `MainActor.assumeIsolated`.
5. **`ConversationCoordinator.init` setup trampoline** — inner `Task { await self.setup() }` strongly captured self; now optional-chained through the weak capture.

**Known pre-existing warnings (left for the Swift 6 batch):** dead `willStreamTTS` branch in `ConversationCoordinator.swift:660`, and `currentSegmentText` sendable-capture warning in `TTSService.swift:233/254`.

**Remaining audit batches (agreed order):** hot-path perf (memoize `parseSegments`, per-chunk TTS cleaning, TTS progress offset cache), `@Observable` migration, `ConversationCoordinator` split, Swift 6 strict concurrency.

---

## 2026-06-10 — ConversationCoordinator Split (audit batch 4)

The coordinator shrank from 1,265 to 1,035 lines by extracting two self-contained domains into controllers. **Zero call-site changes** — the coordinator keeps its public API as thin forwarders, so views, OverlayViewModel, FileTranscriptionModel, and SettingsView are untouched.

**`Orchestration/DisplayResultController.swift` (~175 lines, @Observable)** — owns the display-mode result text (`result`), TTS speaking-segment highlight (`speakingSegment`), the TTS-playback task, and the hover-pausable auto-dismiss countdown. Methods: `show`, `readAloud`, `stopReadAloud`, `scheduleAutoDismiss`, `keepAlive`, `clear`. Depends only on `PreferencesStore` (stateless UserDefaults wrapper — owns its own copy) + `TTSService.shared`. Never touches AppState. Coordinator forwards `displayModeResult`/`ttsSpeakingSegment` as computed properties — observation tracking follows the read into the controller's tracked properties, so OverlayViewModel works unchanged.

**`Orchestration/ModelSessionController.swift` (~440 lines, plain @MainActor — nothing UI-tracked lives here)** — owns the live `stt`/`llm`/`toolExecutor` instances, load/switch tasks, pending-switch flags, all of the old +ModelLifecycle extension, the service factories (`makeSttService`, `makeLLMService`, tool wiring, tool-definitions prompt), and the offload→service-niling ObservationLoop. AppState stays single-source in the coordinator: the controller drives it via injected `getState`/`setState`/`getContextAwareMode`/`scheduleErrorReset` closures (the ActionCoordinator pattern), wired in the coordinator's init.

**Init restructure:** `modelManager` is now assigned in init via a local (`let manager = ModelManager()`) so `models` can be a non-optional `let` constructed in phase 1; the closures are wired right after (escaping-self captures are legal once stored properties are set). `models` is internal, not private, so the +ModelLifecycle forwarder extension (separate file) can reach it.

**What stayed in the coordinator (deliberately, per CLAUDE.md "single orchestration center"):** voice-edit/dictation/grammar-fix pipelines, `presentOutput` routing decision (paste vs display; sets `.pasting`/`.idle`), `editText`/`dictateCommand` (Transcribe-window pipelines), setup, hotkeys, `cancelActiveOperation`, `resetErrorAfterDelay`.

**Pre-existing warning noted (not from this batch):** `OutputCleaner.swift:130` — `var lines` never mutated.

---

## 2026-06-09 — @Observable Migration (audit batch 3)

All six ObservableObject classes migrated to the Observation framework (macOS 14+): `ConversationCoordinator`, `ModelManager`, `PermissionsCoordinator`, `LicenseManager`, `OverlayViewModel`, `FileTranscriptionModel`. Views now re-render only when a property they actually read changes.

**Class changes:** dropped `: ObservableObject` for `@Observable`, removed all `@Published`, marked internals (Tasks, caches, weak refs, callbacks, timers) `@ObservationIgnored`. Two gotchas encountered:
- `@Observable` makes stored properties computed, so a nonisolated `deinit` can no longer touch them — `ModelManager.memoryPressureSource` and `PermissionsCoordinator.pollTimer` must stay `@ObservationIgnored` (plain storage) for their deinit cleanup to compile.
- `@ObservationIgnored` must not be applied to `let` constants (they're never tracked anyway).

**Observation pipelines replaced (Combine `$property` publishers no longer exist):**
- New `Utilities/ObservationLoop.swift` — re-arming `withObservationTracking` wrapper. Key semantic: onChange fires on *willSet* and is one-shot, so the handler is deferred one main-actor turn (reads post-change values — same reason the old Combine code used `.receive(on: RunLoop.main)`) and re-armed. Rapid mutations coalesce; the handler must be idempotent and read current state.
- `OverlayViewModel.observe`: six sinks → one tracked read set + unified `handleCoordinatorChange()` carrying the old per-sink side effects (lastTranscription capture, display-mode line calc gated by `lastDisplayResult`, polling start/stop gated by session identity). Re-subscription handled via `observationGeneration` counter.
- `ConversationCoordinator`: `objectWillChange` forwarding from permissions/modelManager/licenseManager deleted (obsolete — views track nested objects directly); `$sttReady`/`$llmReady` sinks → ObservationLoop.
- `DictationOverlayPanel`: `viewModel.$overlayState.sink` → `onOverlayStateChange` callback fired from `overlayState.didSet` (panel is AppKit, needs every assignment synchronously; Combine fully removed from the file). Callback is set *before* `viewModel.observe(coordinator)` so the initial derive can drive the panel.

**View changes:** `VoiceEditorApp` `@StateObject`→`@State`; `SettingsView` modelManager and `FileTranscriptionView` model → `@Bindable` (they bind `$modelManager.selectedModel`, `$model.editCommand`, etc.); MenuBarMenu / LicenseActivationView / DictationOverlayContent / WaveformBarsView → plain `var`.

**Manual test points after this migration:** overlay state flow (listen → generate → speak → done, Esc dismissal), audio-level waveform during recording, Settings model picker + auto-offload toggle, license activation flow, model offload clearing (wait 5 min idle → menu bar should show models unloaded), Transcribe window edit bar.

---

## 2026-06-09 — Hot-Path Performance (audit batch 2)

Per-token and per-redraw costs in the streaming overlay path. Build verified clean, no new warnings.

1. **`OverlayTextRenderer`** — `segments` was `parseSegments(text)` recomputed on every body evaluation (≥2× per render via `hasComplexContent` + `groupedSegments`, and on every TTS re-render with unchanged text). Now memoized in a bounded 8-entry `SegmentCache` dictionary; struct marked `@MainActor` so the cache needs no lock. Per-token full reparse still happens once as text grows — incremental parsing deferred (would need parser state threading).
2. **`cleanChunkForTTS`** — added a fast-path guard: chunks containing neither `<` nor `` ` `` (the vast majority) skip all 11 `replacingOccurrences` scans. Deliberately did NOT remove per-chunk cleaning — tags split across the final flush path must still never reach TTS.
3. **`OverlayViewModel.deriveState`** — TTS progress (`range(of:)` + `distance`) was recomputed on every published change. Now memoized per (text, segment) with a monotonic search anchor; also fixes repeated sentences matching the first occurrence (progress snapped backwards).
4. **`CodeHighlighter`** — result cache already existed, but streaming code blocks miss it every token; regex compilation (~10 patterns/language) now cached per language in `compiledCache`.
5. **Formatter caching** — `ISO8601DateFormatter`/`DateFormatter` instantiation removed from `buildToolDefinitionsPrompt` (now `ConversationCoordinator.isoDateTimeFormatter`), `ActionRouter.buildPrompt`, and all four CalendarTools helpers (one immutable formatter per format string — `DateFormatter` is only thread-safe if never mutated).
6. **Tool re-generation loop** — `raw.reserveCapacity(4096)` after the `raw = ""` reset (initial loop already had it; audit's claim that it was missing on the first loop was stale).

**Audit corrections:** initial `reserveCapacity` already existed at ConversationCoordinator.swift:553; CodeHighlighter already had a bounded *result* cache (the gap was compiled-pattern caching only).

---

## Post-Initial Changes

### cleanModelOutput — Robust LLM Artifact Stripping

Added to `OutputCleaner.swift`. Uses `NSRegularExpression` with patterns compiled once as static constants.

**Processing order (critical — must be this sequence):**
1. **Complete thinking blocks** — `<think>...</think>`, `<|thinking|>...</|/thinking|>` etc. (case-insensitive, non-greedy `[\s\S]*?`)
2. **Unclosed thinking blocks** — open tag with no close → strip to end of string (generation was cut mid-thought)
3. **Special tokens** — find FIRST occurrence of any leaked token (`<end_of_turn>`, `<|im_end|>`, `[INST]`, `</s>`, etc.) and truncate everything from that point
4. **Final cleanup** — trim whitespace, collapse 3+ newlines to 2

**Integration:** `clean()` now calls `cleanModelOutput()` first, then does preamble/fence/trailing cleanup on top. Both layers work together in the pipeline.

**Why NSRegularExpression:** Patterns need case-insensitive matching and `[\s\S]` for dotall behavior across newlines. Compiled once via `try!` (patterns are known-good). Swift `Regex` would also work on macOS 14+ but NSRegularExpression gives explicit control over options.

### ModelOption + ModelRegistry — Model-Agnostic Wrapper

New file: `Models/ModelOption.swift`

**ModelOption struct:** `id` (HuggingFace ID), `displayName`, `parameterCount`, `quantization`, `estimatedMemoryMB`, `extraEOSTokens`. Generates `ModelConfiguration` via computed property.

**ModelRegistry:** Static list of 5 available models:
- Gemma 3 1B 8-bit (~1.4 GB) — default
- Gemma 2 2B 8-bit (~2.6 GB)
- Qwen 3.5 0.8B 8-bit (~1.1 GB)
- Qwen 3 0.6B 8-bit (~0.9 GB)
- Granite 4 1B 4-bit (~0.8 GB)

**Memory estimation formula:** `(parameters × bits/8) + 300MB overhead` (KV cache + tokenizer + MLX metadata)

**ModelManager updated:** Now takes `ModelOption` instead of hardcoded config. `selectedModel` is `@Published` so settings UI can change it.

**SettingsView updated:** Model picker shows all available models with memory footprint. Separate `@ObservedObject` for `modelManager` to get proper binding for the Picker.

### Build Status After Changes
**0 errors, 0 warnings** — clean build in ~4s (incremental)

---

---

## v1.4 Architecture Notes

### Editability Detection (`EditabilityDetector.swift`, `AXEditabilityDetector.swift`)
Protocol behind a value-type AX implementation. `focusedElementIsEditable()` checks role whitelist (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`) then `kAXInsertionPointLineNumberAttribute` as a fallback for web/contenteditable elements. Fails open (returns true) on any AX error. Electron apps (VS Code, Zed), JetBrains (Swing), and GPU-rendered editors will always return false — result goes to Display Mode overlay.

### Display Mode (`ConversationCoordinator.displayModeResult`)
`@Published` string. When non-empty, `DictationOverlayPanel` shows the result and stays open (ignores `.idle` state change). 20-second auto-clear via a cancellable `Task`. `useDisplayMode: false` on dictation ensures raw transcripts always paste.

### Document Context (`ContextCaptureService.capture(mode:documentBudget:)`)
Advanced mode only. Budget from `ModelOption.documentContextBudget` (0 for None / 600 for <2 GB models / 1500 for <5 GB / 2500 for ≥5 GB). PDF extraction via PDFKit — anchor page from `findString` (skipped for >50-page docs to avoid blocking). Pages/Word via `NSAppleScript` in `Task.detached`. Scanned PDFs return nil → falls back to OCR. OCR (`VNImageRequestHandler.perform`) also moved to `Task.detached` — it's a 50–500ms blocking call that was running on `@MainActor`.

### Polish Dictation (`DictationPolisher.swift`)
Runs in `stopDictation()` only (not voice edit). Calls `llm.generate(prompt:maxTokens:temperature:0.1)` — temperature override added to `LLMService` protocol with default extension so existing callers are unchanged. Prompt instructs model to preserve all meaningful words and remove only vocal hesitations. 85–120% length ratio safety net; falls back to raw transcript silently on any failure.

### LaTeX Rendering (`MathView.swift`, `OverlayTextRenderer` in `DictationOverlayPanel.swift`)
`MathView.renderToImage` returns `(image: NSImage, descent: CGFloat)`. Cache stores tuples. `descent = MTMathListDisplay.descent` applied as `.baselineOffset(-descent)` per inline math image — aligns math baseline with surrounding text. Parser handles `$`, `$$`, `\[...\]`, `\(...\)`.

### Action Mode Extensions
Notes via `NSAppleScript` to Apple Notes. Timer via `UNUserNotificationCenter` (permission requested at app startup in `setup()` for LSUIElement apps). Email via `mailto:` URL with no recipient — compose window only.

---

## Build Status

**First build:** `swift build` — 779 compilation steps, completed in ~30s
- One deprecation warning fixed: `GPU.set(cacheLimit:)` → `Memory.cacheLimit`
- **Final build: 0 errors, 0 warnings**

**Resolved SPM versions:**
- swift-transformers: 1.1.9
- mlx-swift: 0.30.6
- KeyboardShortcuts: 2.4.0
- swift-jinja: 2.3.2
- swift-crypto: 4.2.0
- swift-collections: 1.4.0

---

## File Inventory (22 files)

```
Package.swift                                  # SPM package definition
VoiceEditor/
  VoiceEditorApp.swift                         # @main, MenuBarExtra + Settings scenes
  Info.plist                                   # LSUIElement, mic/speech usage descriptions
  VoiceEditor.entitlements                     # Memory limit, network client
  Models/
    AppState.swift                             # State enum + VoiceEditorError
  Services/
    PermissionsCoordinator.swift               # Accessibility + mic permission management
    TextCaptureService.swift                   # Clipboard save/restore, CGEvent Cmd+C/V
    AudioCaptureService.swift                  # AVAudioEngine recording + RMS silence detection
    STTService.swift                           # Protocol
    FluidAudioSTT.swift                        # Parakeet CoreML on ANE
    AppleSTT.swift                             # SFSpeechRecognizer fallback
    LLMService.swift                           # Protocol
    MLXLLMService.swift                        # MLX Gemma 3 1B on GPU
    ModelManager.swift                         # HuggingFace download + load orchestration
    HotkeyManager.swift                        # KeyboardShortcuts registration
  Orchestration/
    ConversationCoordinator.swift              # Central pipeline orchestrator
    Prompts.swift                              # Edit + draft prompt templates
    OutputCleaner.swift                        # Strip LLM preamble/fences/notes
    DraftDetector.swift                        # Detect draft vs edit commands
    LanguageDetector.swift                     # NLLanguageRecognizer wrapper
    Instructions.swift                         # Localized grammar-fix instructions
  Views/
    MenuBarView.swift                          # Main menu bar popover UI
    SettingsView.swift                         # Settings window (hotkeys, permissions, model)
    OnboardingView.swift                       # First-launch setup flow
    DownloadProgressView.swift                 # Reusable download progress component
  Extensions/
    KeyboardShortcuts+Names.swift              # .voiceEdit + .grammarFix shortcut definitions
```

---

## How to Run

1. Open `Package.swift` in Xcode
2. Select the VoiceEditor scheme
3. In Xcode project settings:
   - Set Info.plist path to `VoiceEditor/Info.plist`
   - Add entitlements from `VoiceEditor/VoiceEditor.entitlements`
   - Disable sandbox
4. Build & Run (Cmd+R)
5. App appears as menu bar icon — first launch shows onboarding
6. Grant Accessibility + Microphone permissions
7. Click "Download Models & Get Started"
8. Use Ctrl+Shift+A (voice edit) or Ctrl+Shift+Z (grammar fix)
