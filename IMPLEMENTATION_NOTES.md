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

1. Open `/Users/omard/Documents/projects/AI_projects/VoiceEditor/Package.swift` in Xcode
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
