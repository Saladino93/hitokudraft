# Swift Rewrite — Implementation Brief

> Canonical build target for a native macOS voice-editing menu bar app.
> For backward-looking prototype analysis, see `NOTES.md`.

---

## 1. Product goal

Build a native macOS menu bar app that lets the user select text in any application,
press a hotkey, speak a voice command, and have the text rewritten in-place by a
small on-device LLM — all locally on Apple Silicon, with no cloud calls.
Optimize for the simplest high-quality local macOS UX, not for maximum framework
optionality.

---

## 2. Primary workflows

### Voice-edit selected text
1. User selects text in any app and presses the voice-edit hotkey.
2. App simulates Cmd+C (saving and later restoring the clipboard), reads `NSPasteboard`.
3. App plays a "listening" sound, records mic audio until 1.5 s of silence.
4. Audio is transcribed locally (FluidAudio). The transcript becomes the editing instruction.
5. Selected text + instruction are sent to the on-device LLM.
6. Result is placed on the pasteboard; app simulates Cmd+V.
7. Original clipboard contents are restored.

### Grammar fix (text-only)
1. User selects text and presses the grammar-fix hotkey.
2. App captures text via Cmd+C (same clipboard-safe flow).
3. Language is auto-detected (`NLLanguageRecognizer`); a localized grammar instruction
   is selected (English, Italian, French, German — extensible).
4. Text + instruction go to the LLM; result is pasted back.

### Draft / generate
- If no text is selected, **or** the voice command contains a generation keyword
  (`draft`, `write`, `compose`, `create`, `generate`, `email`, `letter`, `message`,
  `report`, `memo`, `summary`, `paragraph`, `document`, `essay`),
  the app enters draft mode: the LLM generates new content from the voice instruction
  alone, and the result is pasted at the cursor position.

---

## 3. Architecture

### AppState

A single, explicit state enum drives the entire UI:

```swift
enum AppState: Equatable {
    case idle
    case listening
    case transcribing
    case generating
    case pasting
    case error(String)
}
```

### Module map

| Module | Responsibility |
|--------|----------------|
| `AppShell` | `@main` App, `MenuBarExtra`, `Settings` scene, onboarding |
| `PermissionsCoordinator` | Accessibility (`AXIsProcessTrusted`), Microphone, optional Notifications |
| `HotkeyManager` | Global shortcut registration via `KeyboardShortcuts` |
| `TextCaptureService` | Clipboard-safe selected-text capture (Cmd+C) and paste-back (Cmd+V) |
| `AudioCaptureService` | `AVAudioEngine` mic recording, RMS silence detection (threshold 0.015, limit 1.5 s) |
| `STTService` (protocol) | `transcribe(audioURL:) async throws -> String` |
| `FluidAudioSTT` | Primary `STTService` impl — FluidAudio, Core ML / ANE |
| `AppleSTT` | Fallback `STTService` impl — `SFSpeechRecognizer` (no model download needed) |
| `LLMService` (protocol) | `generate(prompt:maxTokens:) async throws -> String` |
| `MLXLLMService` | `LLMService` impl — `mlx-swift` |
| `ModelManager` | Download from HuggingFace, on-disk cache, warmup, progress reporting |
| `ConversationCoordinator` | Orchestrates the full pipeline and owns `AppState` |
| `FeedbackPresenter` | Transient status popover, error banners, listening indicator |

### ConversationCoordinator

The coordinator is the single orchestration center. It owns the `AppState` and
sequences the pipeline:

```swift
@MainActor
final class ConversationCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle

    private let textCapture: TextCaptureService
    private let audioCapture: AudioCaptureService
    private let stt: any STTService
    private let llm: any LLMService

    func handleVoiceEdit() async { ... }
    func handleGrammarFix() async { ... }
}
```

### Protocol signatures

```swift
protocol STTService: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

protocol LLMService: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func warmup() async throws
}
```

### Key design rules

- **No server.** LLM and STT are direct function calls; no HTTP layer.
- **UI state is read-only outside the coordinator.** Views observe `state` and call
  coordinator methods; they never mutate `state` directly.
- **Long-running inference runs off the main actor.** The coordinator dispatches
  STT and LLM work to background contexts and publishes state updates back to `@MainActor`.
- **Clipboard operations are treated as critical.** Save → use → restore, with
  rollback if any step fails.

---

## 4. STT strategy

### Primary: FluidAudio

[FluidAudio](https://github.com/FluidInference/FluidAudio) is the primary STT engine.

- Written in Swift; integrates naturally with SwiftUI.
- Targets Core ML and Apple Neural Engine (ANE), leaving the GPU free for the LLM.
- Includes in-stream multilingual language detection — fits the language-agnostic
  hotkey workflow where the user may speak commands in any language.
- Includes VAD and speaker diarization APIs.

### Fallback: SFSpeechRecognizer

`SFSpeechRecognizer` (Apple framework) serves as a zero-download fallback:
- Available on all macOS versions without downloading a model.
- Useful during first launch while FluidAudio models are still downloading.
- On-device mode available (set `requiresOnDeviceRecognition = true`).

### Future option: SpeechAnalyzer

Apple's `SpeechAnalyzer` framework (if/when available on macOS) could be evaluated
as a future alternative. It is not a priority for the MVP.

---

## 5. UX principles

### Permission onboarding

On first launch, guide the user through granting:
1. **Accessibility** — required for Cmd+C/V simulation. Check `AXIsProcessTrusted()`;
   if not granted, show a deep link to System Settings > Privacy & Security > Accessibility.
   Gate all hotkey functionality until granted.
2. **Microphone** — required for voice commands. Request via `AVCaptureDevice.requestAccess(for: .audio)`.
3. **Speech Recognition** (if using `SFSpeechRecognizer` fallback) — `SFSpeechRecognizer.requestAuthorization`.

Display a clear checklist UI. Do not silently fail if permissions are missing.

### State feedback

The menu bar icon and/or a transient popover must reflect `AppState`:
- **Idle** — default icon.
- **Listening** — animated icon or pulsing indicator + system "Tink" sound on start.
- **Transcribing / Generating** — spinner or progress text.
- **Pasting** — brief flash; system "Pop" sound on completion.
- **Error** — red icon badge + brief notification with the error message.

Audio cues mirror the Python prototype: play `Tink.aiff` when recording starts,
`Pop.aiff` when the result is pasted.

### Clipboard safety

The clipboard-hack text capture is a destructive operation. Always:
1. Save `NSPasteboard.general` contents (all types) before simulating Cmd+C.
2. Read the captured text.
3. After pasting the result via Cmd+V, restore the original clipboard contents.
4. If any step fails, restore the clipboard and leave the original text untouched.

### Model download progress

On first launch, models must be downloaded from HuggingFace (~1–2 GB total).
- Show a progress view with download size, percentage, and estimated time.
- Allow cancellation.
- Allow the user to use the grammar-fix hotkey with `SFSpeechRecognizer` fallback
  while models are still downloading.

### Failure handling

- If STT fails, do **not** paste garbage. Show a notification and leave original text intact.
- If LLM fails or returns empty output, same: notify and do not paste.
- If the LLM output looks suspiciously like preamble ("Sure, here is…"), apply output
  cleaning (strip preamble lines, trailing disclaimers) before pasting.

### Menu bar style

Use `.menuBarExtraStyle(.window)` for the popover — it provides a proper window
with enough space for status, settings access, and download progress.

### Settings

Use `SettingsLink` to open the Settings scene from the menu bar popover.

**Caveat:** `SettingsLink` only works inside a SwiftUI view hierarchy that is
connected to a `Settings` scene. If it doesn't respond to clicks in the menu bar
popover context, fall back to `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`.

### Hotkey discoverability

- Show the current hotkeys in the Settings window (e.g., "Voice Edit: Ctrl+Shift+A").
- Use `KeyboardShortcuts` (Sindre Sorhus, MIT) for user-configurable global shortcuts.
- Provide sensible defaults.

---

## 6. Model strategy

### LLM tiers (from prototype config)

| Model ID | Size | Notes |
|----------|------|-------|
| `mlx-community/gemma-3-1b-it-8bit` | ~1 GB | Default; good quality for editing |
| `mlx-community/gemma-2-2b-it-8bit` | ~2 GB | Higher quality, slower |
| `mlx-community/Qwen3.5-0.8B-MLX-8bit` | ~0.8 GB | Lightweight alternative |
| `mlx-community/Qwen3-0.6B-8bit` | ~0.6 GB | Smallest option |
| `mlx-community/granite-4.0-h-1b-4bit` | ~0.5 GB | 4-bit, fast |

For MVP, ship with **one default model** (Gemma 3 1B 8-bit). No model-tier selection
UI in v1 — just a config constant that can be changed in a future settings panel.

### STT model

FluidAudio will handle model selection internally. The prototype uses
`mlx-community/whisper-large-v3-mlx` (~1.5 GB). FluidAudio may use a different
model format or size; follow FluidAudio's recommended defaults.

### LoRA / fine-tuning

The Python prototype has `adapter` support in its model config for loading LoRA
weights via `mlx_lm.load()`.

**Warning:** LoRA adapter loading in `mlx-swift` is less mature than the Python
`mlx_lm` side. Before training any LoRA adapters, verify:
- That `mlx-swift` can load the same adapter format produced by `mlx.lora` (Python).
- That inference quality matches between Python and Swift for the same base+adapter.

**LoRA is a non-goal for MVP.** Do not build adapter UI or selection. Just ensure
the `LLMService` protocol could support it in the future.

### Download and warmup flow

1. **First launch:** Check if model files exist in the local cache directory.
2. **If missing:** Show download progress UI. Download from HuggingFace Hub.
3. **After download:** Trigger a warmup pass (generate a few tokens from a dummy prompt)
   to force Metal JIT compilation. The prototype does this with 1 s of silence for
   Whisper and should do the same for the LLM.
4. **Subsequent launches:** Warmup only (no download). Run warmup in a background
   Task at app launch so the first hotkey press is fast.

---

## 7. Reference implementations

Use these as implementation references for specific patterns, not as UX templates.

### mlx-swift-examples

- **`ml-explore/mlx-swift-examples/Applications/LLMEval`** —
  HuggingFace model download, tokenizer/model loading, streaming text generation,
  sandbox/network entitlements, increased memory limits.
- **`ml-explore/mlx-swift-examples/MLXChatExample`** —
  Chat-style app structure, local generation flow, prompt/session management.

### FluidAudio

- **`FluidInference/FluidAudio`** —
  Local STT, VAD, Core ML / ANE audio pipeline. Primary STT reference.

### swift-scribe

- **`AugustDev/swift-scribe`** —
  Open-source macOS transcription app. Shows menu bar integration patterns,
  audio capture, and local STT in a shipping app context.

### WWDC sessions

- **WWDC24: "Bring your machine learning and AI models to Apple Silicon"** —
  MLX on Apple Silicon, model optimization, Neural Engine usage.
- **WWDC23: "What's new in App Intents"** — if adding Shortcuts support later.

---

## 8. Licensing checklist

Licenses must be verified at **two levels**: the Swift package and any bundled model weights.

### Package licenses

| Package | License | Commercial OK? |
|---------|---------|----------------|
| `mlx-swift` (Apple) | MIT | Yes |
| `FluidAudio` | Apache 2.0 (verify exact version) | Yes, with attribution |
| `KeyboardShortcuts` (Sindre Sorhus) | MIT | Yes |
| `mlx-swift-examples` (reference only) | MIT | Yes |

### Model weight licenses

| Model | License | Action required |
|-------|---------|-----------------|
| Gemma 3 (Google) | Gemma Terms of Use | Read full terms; has distribution obligations |
| Qwen 3 / 3.5 (Alibaba) | Qwen License | Allows commercial use up to certain scale; verify current terms |
| Granite 4 (IBM) | Apache 2.0 | Yes, with attribution |
| Whisper (OpenAI) | MIT | Yes |
| FluidAudio bundled models | Verify separately | Check FluidAudio docs for bundled model licenses |

**Do not ship any model without confirming its license.** Package license and model
license are separate concerns — an MIT package can bundle a restrictively-licensed model.

---

## 9. Non-goals (for MVP)

- LoRA adapter loading or fine-tuned model support
- Model tier selection UI
- Conversation history or multi-turn context
- Cloud/API fallback (everything is local-only)
- iOS or iPad version
- App Store distribution (distribute outside the store; no sandbox)
- Streaming STT (batch transcription after silence detection is sufficient)
- Custom VAD model (RMS threshold silence detection is sufficient)
- Multilingual draft-mode keyword list (English keywords only for v1)
- SpeechAnalyzer integration
- Shortcuts / App Intents integration

---

## 10. MVP milestone

The MVP is complete when:

- [ ] App launches as a menu bar utility with `.menuBarExtraStyle(.window)`.
- [ ] First-launch onboarding checks and requests Accessibility + Microphone permissions.
- [ ] Model download progress is shown on first launch; download is cancellable.
- [ ] Models are warmed up in a background Task at launch.
- [ ] Voice-edit hotkey: select text → hotkey → mic records → STT → LLM edits → paste.
- [ ] Grammar-fix hotkey: select text → hotkey → auto-detect language → LLM fixes → paste.
- [ ] Draft mode: no selection + voice command → LLM generates → paste.
- [ ] Clipboard is saved before Cmd+C and restored after Cmd+V.
- [ ] Audio cues play on recording start and result paste.
- [ ] `AppState` is reflected in the menu bar icon and popover.
- [ ] Errors are surfaced as notifications; original text is never clobbered.
- [ ] Settings window with hotkey configuration (via `KeyboardShortcuts`).
- [ ] `SFSpeechRecognizer` fallback works if FluidAudio models are unavailable.

---

## 11. Appendix: starter skeleton

> These stubs show the intended module structure and API surface.
> They are starting points, not production code.

### App entry point

```swift
import SwiftUI
import KeyboardShortcuts

@main
struct VoiceEditorApp: App {
    @StateObject private var coordinator = ConversationCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
```

### AppState

```swift
enum AppState: Equatable {
    case idle
    case downloading(progress: Double)
    case warmingUp
    case listening
    case transcribing
    case generating
    case pasting
    case error(String)

    var isProcessing: Bool {
        switch self {
        case .listening, .transcribing, .generating, .pasting:
            return true
        default:
            return false
        }
    }
}
```

### ConversationCoordinator

```swift
@MainActor
final class ConversationCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle

    private let textCapture = TextCaptureService()
    private let audioCapture = AudioCaptureService()
    private let modelManager = ModelManager()
    private var stt: (any STTService)?
    private var llm: (any LLMService)?

    var menuBarIcon: Image {
        switch state {
        case .listening: return Image(systemName: "mic.fill")
        case .error:     return Image(systemName: "exclamationmark.triangle")
        default:         return Image(systemName: "text.bubble")
        }
    }

    func setup() async {
        state = .downloading(progress: 0)
        do {
            try await modelManager.ensureModels { progress in
                Task { @MainActor in self.state = .downloading(progress: progress) }
            }
            state = .warmingUp
            llm = try await MLXLLMService(modelPath: ModelManager.defaultLLMPath)
            stt = try await FluidAudioSTT()
            try await llm?.warmup()
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func handleVoiceEdit() async {
        guard state == .idle, let stt, let llm else { return }
        do {
            let originalClipboard = textCapture.saveClipboard()
            let selectedText = try textCapture.captureSelectedText()

            state = .listening
            let audioURL = try await audioCapture.recordUntilSilence()

            state = .transcribing
            let command = try await stt.transcribe(audioURL: audioURL)

            state = .generating
            let draftMode = selectedText.isEmpty || isDraftCommand(command)
            let prompt = draftMode
                ? Prompts.draft(instruction: command)
                : Prompts.edit(text: selectedText, instruction: command)
            let result = try await llm.generate(prompt: prompt, maxTokens: draftMode ? 800 : max(500, selectedText.split(separator: " ").count * 3))
            let cleaned = OutputCleaner.clean(result)

            state = .pasting
            try textCapture.pasteText(cleaned)
            textCapture.restoreClipboard(originalClipboard)

            state = .idle
        } catch {
            state = .error(error.localizedDescription)
            // Clipboard restore is handled in TextCaptureService on failure
        }
    }

    func handleGrammarFix() async {
        guard state == .idle, let llm else { return }
        do {
            let originalClipboard = textCapture.saveClipboard()
            let selectedText = try textCapture.captureSelectedText()
            guard !selectedText.isEmpty else { return }

            state = .generating
            let lang = LanguageDetector.detect(selectedText)
            let instruction = Instructions.forLanguage(lang)
            let prompt = Prompts.edit(text: selectedText, instruction: instruction)
            let result = try await llm.generate(prompt: prompt, maxTokens: max(500, selectedText.split(separator: " ").count * 3))
            let cleaned = OutputCleaner.clean(result)

            state = .pasting
            try textCapture.pasteText(cleaned)
            textCapture.restoreClipboard(originalClipboard)

            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
```

### TextCaptureService

```swift
import AppKit
import Carbon.HIToolbox

final class TextCaptureService {
    struct ClipboardSnapshot {
        let items: [NSPasteboardItem]
    }

    func saveClipboard() -> ClipboardSnapshot { ... }
    func restoreClipboard(_ snapshot: ClipboardSnapshot) { ... }

    /// Simulates Cmd+C, waits briefly, reads NSPasteboard.
    /// Requires Accessibility permission.
    func captureSelectedText() throws -> String { ... }

    /// Places text on pasteboard and simulates Cmd+V.
    func pasteText(_ text: String) throws { ... }
}
```

### AudioCaptureService

```swift
import AVFoundation

final class AudioCaptureService {
    private let silenceThreshold: Float = 0.015
    private let silenceDurationLimit: TimeInterval = 1.5

    /// Records mic audio until silence is detected. Returns URL to temp WAV file.
    func recordUntilSilence() async throws -> URL { ... }
}
```

### STT protocol and implementations

```swift
protocol STTService: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

// Primary: FluidAudio (Core ML / ANE)
final class FluidAudioSTT: STTService {
    func transcribe(audioURL: URL) async throws -> String { ... }
}

// Fallback: Apple's on-device speech recognition (no download required)
final class AppleSTT: STTService {
    func transcribe(audioURL: URL) async throws -> String { ... }
}
```

### LLM protocol and implementation

```swift
protocol LLMService: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func warmup() async throws
}

final class MLXLLMService: LLMService {
    // Uses mlx-swift for on-device inference
    // See LLMEval in mlx-swift-examples for model loading pattern
    init(modelPath: String) async throws { ... }
    func generate(prompt: String, maxTokens: Int) async throws -> String { ... }
    func warmup() async throws { ... }
}
```

### Hotkey registration

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let voiceEdit = Self("voiceEdit", default: .init(.a, modifiers: [.control, .shift]))
    static let grammarFix = Self("grammarFix", default: .init(.z, modifiers: [.control, .shift]))
}
```

### Localized instructions

```swift
enum Instructions {
    static let byLanguage: [String: String] = [
        "en": "Fix all grammar, punctuation, and spelling mistakes. Preserve the original meaning and tone.",
        "it": "Correggi tutti gli errori di grammatica, punteggiatura e ortografia. Preserva il significato e il tono originali.",
        "fr": "Corrigez toutes les erreurs de grammaire, de ponctuation et d'orthographe. Préservez le sens et le ton d'origine.",
        "de": "Korrigiere alle Grammatik-, Zeichensetzungs- und Rechtschreibfehler. Behalte die ursprüngliche Bedeutung und den Ton bei."
    ]

    static func forLanguage(_ code: String) -> String {
        byLanguage[code] ?? byLanguage["en"]!
    }
}
```

### Draft-mode detection

```swift
enum DraftDetector {
    private static let triggers: Set<String> = ["draft", "write", "compose", "create", "generate"]
    private static let contentSignals: Set<String> = [
        "email", "letter", "message", "report", "memo",
        "summary", "paragraph", "document", "essay"
    ]

    static func isDraftCommand(_ command: String) -> Bool {
        let words = command.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        if words.prefix(3).contains(where: { triggers.contains($0) }) { return true }
        return words.contains(where: { contentSignals.contains($0) })
    }
}
```
