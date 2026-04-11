# audio_server — Architectural Notes

> Purpose: high-signal overview for translating this Python prototype into a
> modular native macOS menu bar app (SwiftUI + MLX + local STT).

---

## What the repo does

A local voice-and-text AI editing assistant for macOS.
The user selects text in any app, presses a hotkey, optionally speaks a command,
and the selected text is rewritten (or new text is generated) by a small on-device LLM.
Everything runs locally on Apple Silicon; no cloud calls.

---

## Main user workflows

### 1. Voice-edit selected text (Ctrl+Shift+A or similar)
1. User selects text in any app and presses the hotkey.
2. macOS Automator triggers `automator_client.py`, passing the selected text as `argv[1]`.
3. Script records mic audio until 1.5 s of silence.
4. POSTs `{text, audio_file}` to `POST /voice_edit` on the local server.
5. Server transcribes audio → detects mode → calls LLM → returns edited text.
6. Client pastes result via AppleScript Cmd+V.

### 2. Text-only grammar fix (separate hotkey)
1. User selects text → hotkey triggers `automator_grammar.py`.
2. POSTs `{text}` to `POST /edit`.
3. Server calls LLM → returns edited text → client pastes.

### 3. Draft / generate mode (no selection or generation keyword spoken)
- If no text is selected **or** voice command contains a generation keyword
  (write, compose, draft, create, email, …) → server generates new content
  from the voice command alone; selected text is ignored.

---

## Runtime lifecycle

```
$ python server.py          # starts FastAPI on :8000, loads LLM + STT into memory
  └─ GrammarEditor.__init__    # loads mlx_lm model (~few seconds, one-time)
  └─ VoiceTranscriber.__init__ # loads mlx_whisper + warmup (one-time Metal JIT)

# On each hotkey press:
Automator → automator_client.py → HTTP POST → server → transcriber → editor → response
                                                                            ↓
                                         AppleScript Cmd+V ← automator_client.py
```

The server stays alive; the client scripts are ephemeral per-keypress processes.

---

## Modules and responsibilities

| File | Role |
|------|------|
| `server.py` | FastAPI app; exposes `/edit` and `/voice_edit`; owns draft-mode logic |
| `editor.py` | LLM wrapper (`mlx_lm`); builds prompts; edit vs draft mode; output cleaning |
| `transcriber.py` | STT wrapper (`mlx_whisper`); silence-prefix padding; warmup |
| `automator_client.py` | Mic recording; silence detection; POST to server; AppleScript paste |
| `automator_grammar.py` | Text-only POST to server; AppleScript paste |
| `config.py` | Model registry; per-language editing instructions; test data |

---

## Data flow

```
[Mic] ──sounddevice──► [WAV file]
[Selected text] ──argv──► automator_client.py
                                │
                    HTTP POST /voice_edit
                    {text, audio_file}
                                │
                           server.py
                          /voice_edit
                           │        │
                    transcriber    editor
                   mlx_whisper   mlx_lm
                   (audio→text) (text→text)
                           │        │
                     heard_text   edited_text
                                │
                          JSON response
                                │
                    automator_client.py
                                │
                         AppleScript Cmd+V
                                │
                    [Text pasted in active app]
```

---

## Key dependencies

| Library | Role | Swap-friendly? |
|---------|------|---------------|
| `mlx_lm` | LLM inference on Apple Silicon | Yes — swap model ID in config |
| `mlx_whisper` | STT on Apple Silicon | Yes — slot is isolated in `transcriber.py` |
| `fastapi` / `uvicorn` | REST server | Disappears in Swift (no server needed) |
| `sounddevice` | Mic capture + RMS silence detection | Replace with `AVAudioEngine` |
| `soundfile` / `numpy` | Audio file I/O and padding | Replace with `AVFoundation` |
| `langdetect` | Auto-detect text language for instruction routing | Replace with `NLLanguageRecognizer` |
| `requests` | HTTP client (client → server) | Disappears in Swift (direct function calls) |
| macOS Automator | Hotkey binding and selected-text capture | Replace with `Accessibility API` + `CGEvent` |
| AppleScript (`osascript`) | Simulate Cmd+V paste | Replace with `CGEvent` paste simulation |

---

## Architectural patterns and extension points

**Layered, single-responsibility modules** — each of the 5 files has one job;
layers are connected only through simple data types (strings, file paths, JSON).

**Config-driven model registry** — adding or swapping a model is one dict entry
in `config.py` plus flags (`is_qwen`, `supports_system`, `adapter`).
Easy to port this concept to a Swift `AppConfig` struct.

**Draft-mode routing** — keyword list in `server.py` determines edit vs generate.
Clean extension point: add new keywords or a smarter intent classifier here.

**STT slot is swappable** — `transcriber.py` is a thin wrapper; only `.process(path) → (text, latency)`.
Replacing with Moonshine or any other model requires changing one file.

**LLM slot is swappable** — `editor.py` only exposes `.process(text, instruction, draft_mode) → (text, latency, tps)`.
Any `mlx_lm`-compatible model works; adapter (LoRA) support is built in via the `adapter` field in the model config.

**Fine-tuned models via LoRA (planned)** — future models will be fine-tuned with `mlx.lora` (Python) and loaded
as LoRA adapters on top of a base model. The `editor.py` already supports this: set `adapter = "<path>"` in the
model config and `mlx_lm.load()` merges the adapter at load time.
In Swift (`mlx-swift`), LoRA adapter loading is supported but less mature than the Python side — verify
`mlx-swift` LoRA API compatibility before committing to a specific base model + adapter format.

**Silence-based turn detection** — RMS threshold (0.015) and 1.5 s limit are top-level constants; easy to tune.

---

## Constraints and assumptions for Swift rewrite

- **Accessibility permission required** — simulating Cmd+C/V and reading selected
  text requires `AXIsProcessTrusted()`; must be granted by user in System Settings.
- **No server needed** — in Swift the LLM and STT services are direct function calls,
  not HTTP; the REST layer disappears entirely.
- **Selected-text capture** — the Python version receives text via Automator `argv`.
  In Swift, use `CGEvent` to simulate Cmd+C, wait ~100 ms, then read `NSPasteboard`.
- **Paste** — same `CGEvent` Cmd+V trick as Python AppleScript. Needs accessibility.
- **STT language is hardcoded to English** in `transcriber.py` even though
  `config.py` has multilingual editing instructions. Likely intentional (voice commands
  are English), but worth confirming before rewriting.
- **Draft-mode keyword list is English-only** — if multilingual voice commands are
  needed, this list must be expanded.
- **Model sizes** — current default is Gemma 3 1B 8-bit (~1 GB). Config lists options
  up to 2B 8-bit (~2 GB). Whisper Large v3 adds ~1.5 GB. Plan for <4 GB total footprint
  on first launch; offer a <1 GB "lite" tier.
- **Warmup latency** — both MLX models do a one-time JIT warmup on first use.
  In Swift, trigger this at app launch (background Task) before the first hotkey press.

---

## Swift migration notes

| Python piece | Swift equivalent |
|---|---|
| Automator hotkey binding | `KeyboardShortcuts` SPM package (Sindre Sorhus) |
| Selected text capture | CGEvent Cmd+C → `NSPasteboard.general` |
| Paste result | CGEvent Cmd+V |
| Mic recording + silence detection | `AVAudioEngine` + RMS on sample buffer |
| STT (`mlx_whisper`) | **FluidAudio** (Core ML / ANE) or `SFSpeechRecognizer` (on-device) |
| LLM (`mlx_lm`) | `mlx-swift` + `mlx-swift-examples` LLMEval pattern |
| Language detection | `NLLanguageRecognizer` (Apple, on-device) |
| REST server | No server — use Swift protocols / actors directly |
| Config registry | Swift `enum` + `struct ModelConfig` |
| Menu bar + settings window | `MenuBarExtra` + `Settings` scene (SwiftUI) |

**Recommended module split for Swift:**
- `HotkeyManager` — global shortcut registration
- `TextCaptureService` — clipboard-hack selected-text read/write
- `AudioCaptureService` — AVAudioEngine + VAD / silence detection
- `STTService` (protocol) — concrete impl: FluidAudio or SFSpeechRecognizer
- `LLMService` (protocol) — concrete impl: mlx-swift
- `ConversationCoordinator` — owns the pipeline: audio → STT → LLM → paste
- `AppSettings` / `ModelRegistry` — replaces `config.py`

---

## FluidAudio vs mlx-audio-swift for STT

> Assessment is based on public repo information; not verified from this codebase.

**FluidAudio** (`github.com/FluidInference/FluidAudio`) is the stronger choice for a
native Swift app because:
- Written in Swift; integrates naturally with SwiftUI.
- Targets Core ML and Apple Neural Engine (ANE), leaving GPU free for the LLM.
- Includes VAD and speaker diarization APIs out of the box.
- Cleaner public API than hand-wrapping an MLX Python model in Swift.

**mlx-audio-swift** (`github.com/Blaizzy/mlx-audio-swift`) exists but is
primarily a Swift wrapper for the same MLX inference path used in the Python repo.
It is less mature for production ASR and competes for GPU with the LLM.

**Recommendation:** Use FluidAudio for STT + mlx-swift for the LLM.

**License / commercial use — what needs verification:**
- `FluidAudio` — Apache 2.0 at package level; verify exact version and any bundled model/component licenses before shipping.
- `mlx-swift` — MIT license (Apple); commercial use appears allowed.
- `KeyboardShortcuts` — MIT license (Sindre Sorhus); commercial use allowed.
- HuggingFace model weights (Gemma, Qwen, Granite, Whisper) — each has its own
  license. Gemma: has its own terms and distribution obligations; commercial use requires
  checking the current Gemma Terms carefully. Whisper: MIT. Qwen: Qwen License (allows
  commercial use up to certain scale; verify). Granite: Apache 2.0.
  **Do not ship a model without confirming its license.**

---

## Reference implementations for Swift rewrite

Use these as implementation references, not as UIs to copy:

- **`ml-explore/mlx-swift-examples/Applications/LLMEval`** —
  Local HF model download, tokenizer/model loading, streaming text generation.
  Closest official example for embedding an MLX LLM inside a Swift app.
  Documents sandbox/network entitlements and increased memory limits.

- **`ml-explore/mlx-swift-examples` / `MLXChatExample`** —
  Chat-style app structure, local generation flow, prompt/session management.

- **`FluidInference/FluidAudio`** —
  Local STT, VAD, Apple-first audio pipeline.
  Stronger fit than mlx-audio-swift for production Swift STT in this app shape.

- **`Blaizzy/mlx-audio-swift`** —
  Fallback reference if FluidAudio doesn't work out. MLX-based, so competes for GPU.

---

## UX and product requirements

Since the target is a menu bar utility sold outside the App Store:

- **First-launch onboarding** — prompt for Accessibility and Microphone permissions;
  guide user to System Settings. Gate hotkey functionality until granted.
- **Model download progress** — first launch downloads models from HuggingFace.
  Show download progress, size estimate, and allow cancellation.
- **Hotkey discoverability** — default hotkeys shown in settings; user-configurable
  via `KeyboardShortcuts` preference pane.
- **Microphone state feedback** — clear visual indicator (menu bar icon change or
  animation) when the app is listening.
- **Non-destructive text replacement** — preserve clipboard state: save clipboard
  before Cmd+C, restore after Cmd+V. Prevent data loss from the clipboard hack.
- **Failure handling** — if STT or LLM fails, do not paste garbage; show a brief
  notification and leave the original text intact.
- **Warmup** — trigger model warmup at launch in a background Task so the first
  hotkey press is fast.

---

## Open questions

1. **Exact hotkey modifiers** — user notes say Ctrl+Shift+A/Z; repo code shows no
   hotkey library. The Automator workflows are not in the repo. Confirm before rewriting.
2. **Multilingual voice commands** — STT is English-only but editing instructions are
   multilingual. Intentional design or oversight?
3. **Selected-text capture path** — is Automator passing the selection via
   `argv[1]`, or is there a Cmd+C step before calling the script? Needs verification
   with the actual Automator workflow file.
4. **LoRA adapter in Swift** — `editor.py` supports `adapter` (LoRA path) via `mlx_lm.load()`.
   Fine-tuned models trained with `mlx.lora` are a planned feature. Verify that `mlx-swift`
   can load the same LoRA adapter format before training begins — adapter format compatibility
   between Python `mlx_lm` and `mlx-swift` should be confirmed early to avoid rework.
5. **FluidAudio streaming vs batch** — public docs emphasize near real-time and
   batch/programmatic APIs; production-quality streaming behavior should still be
   tested in-app before committing to the streaming path.
6. **Model download UX** — models are pulled from HuggingFace on first use; the Python
   app has no download progress UI. The Swift app needs a first-launch model download flow.
7. **Moonshine alternative** — test files for Moonshine v1 and v2 exist, suggesting it
   was evaluated. Was it ruled out for quality or API reasons?

---

## Component summary table

| Component | Purpose | Swift replacement | Portability risk | License / verify |
|-----------|---------|-------------------|-----------------|-----------------|
| Automator workflow | Hotkey binding + text pass-through | `KeyboardShortcuts` SPM | Low | MIT |
| `automator_client.py` | Record audio, POST, paste result | `AudioCaptureService` + `TextCaptureService` | Low | — |
| `automator_grammar.py` | Text-only POST, paste result | `TextCaptureService` + `LLMService` | Low | — |
| `server.py` | REST orchestration, draft-mode logic | `ConversationCoordinator` actor | Low (logic is simple) | — |
| `editor.py` (mlx_lm) | LLM inference + LoRA adapter loading | `mlx-swift` | Medium (LoRA format + API differences; **verify early**) | MIT |
| `transcriber.py` (mlx_whisper) | STT inference | `FluidAudio` (preferred) | Medium (model format) | Apache 2.0 (verify FluidAudio) |
| `config.py` | Model registry + instructions | `AppSettings` struct / enum | Low | — |
| `sounddevice` capture | Mic + RMS silence detection | `AVAudioEngine` | Low | MIT |
| `langdetect` | Language detection | `NLLanguageRecognizer` | Low | Apple (free) |
| AppleScript Cmd+V | Paste simulation | `CGEvent` | Low (needs Accessibility) | Apple (free) |
| Gemma 3 1B weights | Default LLM | Same (mlx-community) | Low | **Verify Google Gemma license** |
| Whisper Large v3 weights | Default STT | FluidAudio Parakeet or same | Medium | MIT (OpenAI Whisper) |

## Swift architecture target

The Swift rewrite should be a native macOS menu bar app built around `MenuBarExtra`
with a small settings window and a service-oriented architecture.

Preferred module boundaries:
- `AppShell` — app lifecycle, menu bar UI, onboarding, settings window
- `PermissionsCoordinator` — Accessibility, Microphone, optional Notifications
- `HotkeyManager` — user-configurable global shortcuts
- `TextCaptureService` — selected-text capture, clipboard preservation, paste-back
- `AudioCaptureService` — microphone recording, silence detection, optional VAD
- `STTService` — protocol, preferably backed by FluidAudio
- `LLMService` — protocol, backed by mlx-swift
- `ModelManager` — download, install, warmup, storage quotas, model tier selection
- `ConversationCoordinator` — orchestrates text/audio → STT → LLM → output
- `FeedbackPresenter` — transient status UI, errors, progress, listening state

State rules:
- UI state should be simple and explicit: idle, listening, transcribing, generating, pasting, error
- Long-running inference and model downloads should be isolated from UI code
- Clipboard and text replacement should be treated as critical operations with rollback-safe behavior
