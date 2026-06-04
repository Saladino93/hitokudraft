# Hitoku Pro — Cross-Platform Professional Dictation

> **Status:** Planning — no code written yet
> **Date:** 2026-05-25
> **Branch:** `dev/cross-platform`
> **Author:** Omar + Claude
>
> Copy this file into the new repo when created.

---

## Table of Contents

1. [Product Vision](#1-product-vision)
2. [Competitive Analysis](#2-competitive-analysis)
3. [Scope & Phases](#3-scope--phases)
4. [Architecture](#4-architecture)
5. [STT Models & Selection](#5-stt-models--selection)
6. [Backend Strategy Per Platform](#6-backend-strategy-per-platform)
7. [Audio Pipeline](#7-audio-pipeline)
8. [Streaming Architecture](#8-streaming-architecture)
9. [Text Pipeline](#9-text-pipeline)
10. [Technology Stack](#10-technology-stack)
11. [Repo Structure](#11-repo-structure)
12. [Build Instructions: macOS](#12-build-instructions-macos)
13. [Build Instructions: Windows](#13-build-instructions-windows)
14. [Build Instructions: CI/CD](#14-build-instructions-cicd)
15. [Windows Development Environment](#15-windows-development-environment)
16. [Producing a Windows Build for Testing](#16-producing-a-windows-build-for-testing)
17. [Mobile Strategy (iOS & Android)](#17-mobile-strategy-ios--android)
18. [Development Roadmap](#18-development-roadmap)
19. [Risks & Mitigations](#19-risks--mitigations)
20. [Success Metrics](#20-success-metrics)
21. [Open Questions](#21-open-questions)
22. [Appendices](#appendices)

---

## 1. Product Vision

### One sentence

The only professional dictation tool that runs entirely on-device — Wispr Flow quality without sending a single byte to the cloud.

### Target users

- **Lawyers** (Switzerland, EU, UK) handling client-privileged communications
- **Doctors** dictating clinical notes under GDPR / Swiss medical confidentiality law (StGB Art. 321)
- **Consultants and executives** who value privacy and speed
- **Multilingual professionals** — German, French, Italian, English with code-switching mid-sentence

### Why this wins

No existing product combines:
1. On-device STT (privacy)
2. On-device LLM cleanup (quality)
3. Cross-platform (macOS + Windows + mobile)
4. Custom vocabulary (medical/legal terms)
5. Multilingual code-switching

| Competitor | Fatal flaw for our market |
|-----------|--------------------------|
| Wispr Flow | Cloud-only — disqualified for regulated professions |
| Dragon NaturallySpeaking | Abandoned, Windows-only, $700 |
| SuperWhisper | No AI cleanup, no medical/legal vocab |
| macOS/Windows Dictation | ~88% accuracy — correcting every 8th word is unacceptable |
| Apple SpeechAnalyzer | Black box, no custom vocabulary, iOS 26+ only |

### Pricing target

- **Professional:** $25/month or $350 lifetime
- **Enterprise:** $20/user/month (5+ seats), centralized config, audit log
- **Free tier:** 30 minutes/day with smallest model (hook users, convert to paid)

---

## 2. Competitive Analysis

### Detailed comparison

| Feature | Wispr Flow | SuperWhisper | Dragon Pro | macOS Built-in | **Hitoku Pro** |
|---------|-----------|-------------|-----------|---------------|---------------|
| On-device STT | No | Yes (Whisper) | Yes | Yes | **Yes** |
| On-device AI cleanup | No | No (BYOK cloud) | Basic | No | **Yes (Phase 2)** |
| Cross-platform | Mac+Win+Mobile | Mac+Win+iOS | Windows only | Per-OS | **Mac+Win+iOS+Android** |
| Medical/legal vocab | No | No | Yes ($700+) | No | **Yes** |
| GDPR / Swiss privacy | Weak (US cloud) | Strong | Weak (cloud) | Strong | **Strong** |
| Multilingual | 100+ (cloud) | Whisper langs | Limited EU | Limited | **52+ (Qwen3-ASR)** |
| Code-switching | Yes (cloud) | Limited | No | No | **Yes** |
| GPU acceleration | N/A (cloud) | Metal only | CPU | CPU | **Metal+CUDA+DirectML+Vulkan** |
| Streaming preview | Yes | Chunked | Yes | Yes | **True streaming + final pass** |
| Custom vocabulary | No | No | Yes | No | **Yes** |
| Pricing | $15/mo | $250 lifetime | $700 | Free | **$25/mo or $350 lifetime** |
| Active development | Yes | Yes | No (abandoned) | Apple-paced | **Yes** |

### Key insight

Swiss healthcare professionals face **criminal sanctions** (StGB Art. 321) for confidentiality breaches. Lawyers face disbarment. Cloud-only products are structurally disqualified. This is not a preference — it's a legal requirement that creates a moat.

---

## 3. Scope & Phases

### Phase 1: STT Core (Weeks 1-16)

Standalone cross-platform dictation. No LLM, no actions — just world-class speech-to-text.

- [ ] System-wide hold-to-talk dictation (any text field, any app)
- [ ] Real-time streaming transcription with live word preview
- [ ] Automatic punctuation and capitalization
- [ ] Automatic language detection (DE, FR, IT, EN minimum)
- [ ] Code-switching within a single utterance
- [ ] Filler word removal (uh, um, euh, ähm)
- [ ] Multiple quality modes: Fast (streaming) / Accurate (batch)
- [ ] Custom vocabulary / hot-words (medical terms, legal terms, names)
- [ ] Hardware-accelerated inference (Metal, CUDA, DirectML, Vulkan)
- [ ] Menu bar (macOS) / system tray (Windows) with global hotkey
- [ ] Model download manager with first-run setup wizard
- [ ] Zero network calls after model download
- [ ] Per-app profiles (formal for email, casual for chat)
- [ ] Keyboard shortcut customization

### Phase 2: LLM Polish (Weeks 17-24)

- [ ] On-device LLM text cleanup (grammar, restructuring, tone)
- [ ] Voice editing mode (select text → speak instruction → rewrite)
- [ ] Draft mode (speak → generate formatted content)
- [ ] Prompt templates per profession (medical note, legal memo, email)
- [ ] Multi-turn conversation context

### Phase 3: Transcription Toolkit (Weeks 25-32)

- [ ] Long-form file transcription (drag & drop audio/video)
- [ ] Speaker diarization (who said what)
- [ ] Timestamp export (SRT, VTT, JSON, DOCX)
- [ ] Meeting transcription with speaker labels
- [ ] Searchable transcript archive with full-text search
- [ ] Export to Word, PDF, plain text

### Phase 4: Mobile (Weeks 33-40)

- [ ] iOS keyboard extension (custom keyboard for system-wide dictation)
- [ ] iOS standalone app (file transcription, settings)
- [ ] Android IME (Input Method Editor)
- [ ] Android standalone app
- [ ] Mobile model tiering (smaller models for RAM-constrained devices)

### Phase 5: Enterprise (Weeks 41+)

- [ ] MSI/MSIX installer with Group Policy support
- [ ] Centralized configuration (admin deploys settings to all users)
- [ ] Compliance audit log (prove no data left the device)
- [ ] Custom fine-tuned models per domain
- [ ] API for integration with practice management software (Clio, PracticePanther)
- [ ] FHIR-compatible medical note export

---

## 4. Architecture

### 4.1 Design Principles

1. **One product, one frontend, one behavior everywhere.** Qt 6 is the unified desktop frontend for macOS, Windows, and Linux. Users get identical UX across platforms. Mobile (iOS/Android) uses native frontends only where platform APIs require it (keyboard extensions, IME).

2. **Shared interfaces, native inference.** The Rust core owns audio pipeline, VAD, text pipeline, model policy, and state machine. It does NOT run the neural network — each platform uses its native ML runtime.

3. **No runtime dependencies beyond Qt.** Single binary + Qt libs + model files. No Python, no Node, no JVM, no .NET. Professionals install it and it works.

4. **Memory-conscious.** A 600M STT model should use <800MB peak. Never exceed 2GB for STT-only. Auto-unload after inactivity.

5. **Streaming-first.** Audio → transcription → display is a continuous pipeline, not batch.

### 4.2 System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Frontends                                  │
│                                                                         │
│  ┌──────────────────────────────────────┐ ┌───────────┐ ┌────────────┐ │
│  │  Qt 6 Desktop (C++) — ONE CODEBASE   │ │iOS (Swift)│ │Android     │ │
│  │                                      │ │Keyboard   │ │(Kotlin)    │ │
│  │  macOS: menu bar, global hotkeys,    │ │extension  │ │IME service │ │
│  │         pasteboard, Accessibility    │ │+ Settings │ │+ Settings  │ │
│  │  Windows: system tray, hotkeys,      │ │app        │ │app         │ │
│  │           clipboard, UI Automation   │ │           │ │            │ │
│  │  Linux: system tray, X11/Wayland     │ │(Phase 4)  │ │(Phase 4)   │ │
│  │         hotkeys, xdotool/wtype       │ │           │ │            │ │
│  └──────────────────┬───────────────────┘ └─────┬─────┘ └─────┬──────┘ │
│                     │                           │              │        │
│  ┌──────▼────────────────▼───────────────▼────────────────▼──────────┐  │
│  │                      C FFI Boundary                               │  │
│  │  hitoku_init() hitoku_start_session() hitoku_feed_audio()         │  │
│  │  hitoku_stop_session() hitoku_get_result() hitoku_set_config()    │  │
│  │  hitoku_load_model() hitoku_unload_model() hitoku_destroy()       │  │
│  └──────────────────────────┬────────────────────────────────────────┘  │
│                             │                                           │
│  ┌──────────────────────────▼────────────────────────────────────────┐  │
│  │                    hitoku-core (Rust)                              │  │
│  │                                                                    │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌───────────────────────────┐  │  │
│  │  │ Audio Engine  │ │ Orchestrator │ │ Text Pipeline             │  │  │
│  │  │              │ │ (State FSM)  │ │                           │  │  │
│  │  │ • Resample   │ │              │ │ • Filler removal          │  │  │
│  │  │   to 16kHz   │ │ idle         │ │ • Punctuation fix         │  │  │
│  │  │ • Ring buffer│ │ → loading    │ │ • Capitalization          │  │  │
│  │  │ • VAD        │ │ → ready      │ │ • Number formatting      │  │  │
│  │  │ • Chunking   │ │ → streaming  │ │ • Hot-word substitution   │  │  │
│  │  │ • Format     │ │ → draining   │ │ • Per-app profile apply   │  │  │
│  │  │   conversion │ │ → error      │ │ • Language detection      │  │  │
│  │  └──────┬───────┘ │ → unloading  │ └───────────────────────────┘  │  │
│  │         │         └──────┬───────┘                                 │  │
│  │         │                │                                         │  │
│  │  ┌──────▼────────────────▼─────────────────────────────────────┐   │  │
│  │  │            Inference Adapter (trait SpeechRecognizer)        │   │  │
│  │  │                                                             │   │  │
│  │  │  fn load_model(path, config) -> Result<()>                  │   │  │
│  │  │  fn transcribe_stream(audio_chunks) -> Stream<Partial>      │   │  │
│  │  │  fn transcribe_batch(audio_buffer) -> Result<Final>         │   │  │
│  │  │  fn supported_languages() -> Vec<Language>                  │   │  │
│  │  │  fn unload() -> Result<()>                                  │   │  │
│  │  │  fn capabilities() -> BackendCaps                           │   │  │
│  │  └─────────────────────────┬───────────────────────────────────┘   │  │
│  │                            │                                       │  │
│  │  ╔═══════════════╦════════╧════════╦═══════════════╗               │  │
│  │  ║ whisper.cpp   ║  ONNX Runtime   ║ Platform      ║               │  │
│  │  ║ (C FFI)       ║  (ort crate)    ║ Native        ║               │  │
│  │  ║               ║                 ║               ║               │  │
│  │  ║ • Metal       ║  • CoreML EP    ║ macOS: MLX    ║               │  │
│  │  ║ • CUDA        ║  • CUDA EP      ║ macOS: Speech ║               │  │
│  │  ║ • Vulkan      ║  • DirectML EP  ║   Analyzer*   ║               │  │
│  │  ║ • CPU         ║  • QNN EP (NPU) ║ iOS: CoreML   ║               │  │
│  │  ║               ║  • CPU          ║ Android: NNAPI║               │  │
│  │  ╚═══════════════╩═════════════════╩═══════════════╝               │  │
│  │                                                                    │  │
│  │  * SpeechAnalyzer = optional "zero-download" tier, not primary     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 State Machine

```
                    ┌──────────┐
           ┌───────│   idle   │◄──────────────┐
           │       └────┬─────┘               │
           │            │ load_model()        │ unload() or error
           │       ┌────▼─────┐               │
           │       │ loading  │───────────────►│
           │       └────┬─────┘               │
           │            │ model ready         │
           │       ┌────▼─────┐               │
           │       │  ready   │◄──────┐       │
           │       └────┬─────┘       │       │
           │            │ start()     │ done  │
           │       ┌────▼─────┐       │       │
           │       │streaming │───────┘       │
           │       └────┬─────┘               │
           │            │ end-of-speech       │
           │       ┌────▼─────┐               │
           │       │ draining │───────────────┘
           │       └────┬─────┘
           │            │ final result ready
           │       ┌────▼─────┐
           └───────│  done    │ → paste/display result → back to ready
                   └──────────┘
```

States:
- **idle** — No model loaded. Waiting for user to select a model.
- **loading** — Model downloading or loading into memory. Show progress.
- **ready** — Model loaded, listening for hotkey press.
- **streaming** — Hotkey held, capturing audio, streaming partial results.
- **draining** — Hotkey released, final transcription pass running.
- **done** — Final result ready. Paste into focused field or display in overlay.
- **error** — Something went wrong. Show message, offer retry. Transition back to idle or ready.

### 4.4 Backend Auto-Selection

At startup, the core detects hardware and selects the best backend:

```
detect_platform()
  ├─ macOS + Apple Silicon
  │    → Primary: MLX (if available) or whisper.cpp Metal
  │    → Fallback: ONNX Runtime CoreML EP
  │    → Optional: SpeechAnalyzer (zero-download quick start)
  │
  ├─ macOS + Intel
  │    → Primary: whisper.cpp CPU (AVX2/SSE)
  │    → Fallback: ONNX Runtime CPU
  │
  ├─ Windows + NVIDIA GPU
  │    → Primary: whisper.cpp CUDA
  │    → Fallback: ONNX Runtime CUDA EP
  │
  ├─ Windows + AMD GPU
  │    → Primary: ONNX Runtime DirectML EP
  │    → Fallback: whisper.cpp Vulkan
  │
  ├─ Windows + Intel GPU/iGPU
  │    → Primary: ONNX Runtime DirectML EP
  │    → Fallback: whisper.cpp Vulkan
  │
  ├─ Windows ARM (Snapdragon X)
  │    → Primary: ONNX Runtime QNN EP (Hexagon NPU)
  │    → Fallback: ONNX Runtime DirectML EP
  │
  ├─ iOS
  │    → Primary: CoreML (ANE + GPU)
  │    → Optional: SpeechAnalyzer
  │
  └─ Android
       → Primary: ONNX Runtime Mobile
       → Fallback: LiteRT (NNAPI delegate)
```

Detection logic:
1. Enumerate GPUs (Metal API / DXGI / Vulkan)
2. Check CUDA availability (`dlopen("libcuda")` / `LoadLibrary("nvcuda.dll")`)
3. Check DirectML availability (Windows only)
4. Score each backend: available × GPU-accelerated × model-support × benchmarked-speed
5. Select highest-scoring, set fallback chain
6. Log selection for diagnostics

---

## 5. STT Models & Selection

### Available models

| Model | Params | Disk | RAM (est.) | WER (EN) | Languages | Streaming | Best For |
|-------|--------|------|-----------|----------|-----------|-----------|----------|
| Moonshine v2 Tiny | 26M | 27MB | ~100MB | 12.7% | EN+6 | Native | Ultra-low latency preview |
| Moonshine v2 Small | 49M | 123MB | ~300MB | 7.8% | EN+6 | Native | Fast mode on weak hardware |
| Parakeet-TDT 0.6B v3 | 600M | ~700MB | ~900MB | ~6% | 25 EU | Native | Balanced multilingual |
| Whisper large-v3-turbo | 809M | 1.6GB | ~2GB | ~8% | 99 | Chunked | Maximum language coverage |
| Qwen3-ASR 0.6B | 600M | ~800MB | ~1GB | ~6% | 52 | Batch | High accuracy, compact |
| Qwen3-ASR 1.7B | 1.7B | 3.4GB | ~4GB | ~5% | 52 | Batch | Maximum accuracy |

### Default model per device tier

| Device Tier | RAM | Default Model | Upgrade Path |
|------------|-----|---------------|-------------|
| Budget phone (3-4GB) | 3-4GB | Moonshine v2 Small (123MB) | — |
| Standard phone (6-8GB) | 6-8GB | Parakeet-TDT 0.6B (700MB) | Qwen3-ASR 0.6B |
| Laptop/desktop (8GB) | 8GB | Whisper large-v3-turbo (1.6GB) | Qwen3-ASR 0.6B |
| Pro desktop (16GB+) | 16GB+ | Qwen3-ASR 0.6B (800MB) | Qwen3-ASR 1.7B |
| Workstation (32GB+) | 32GB+ | Qwen3-ASR 1.7B (3.4GB) | — |

### Model download & management

- First-run wizard: select language(s) → recommended model auto-selected
- Storage locations:
  - macOS: `~/Library/Application Support/HitokuPro/models/`
  - Windows: `%LOCALAPPDATA%\HitokuPro\models\`
  - iOS: app container `Documents/models/`
  - Android: app internal storage `files/models/`
- Download from HuggingFace Hub with resume-on-interrupt
- SHA256 integrity verification after download
- Background download with progress callback to UI
- Model size shown before download ("This will use 1.6 GB of disk space")

---

## 6. Backend Strategy Per Platform

### macOS (Apple Silicon)

```
                      ┌─────────────────────┐
                      │   macOS App (Swift)  │
                      │   AppKit + SwiftUI   │
                      └──────────┬──────────┘
                                 │ C FFI
                      ┌──────────▼──────────┐
                      │  hitoku-core (Rust)  │
                      │  Audio + VAD + Text  │
                      └──────────┬──────────┘
                                 │
               ┌─────────────────┼─────────────────┐
               ▼                 ▼                  ▼
        ┌────────────┐  ┌──────────────┐  ┌──────────────────┐
        │ whisper.cpp │  │ MLX (via     │  │ SpeechAnalyzer   │
        │ Metal GPU   │  │ mlx-swift    │  │ (optional, free) │
        │             │  │ called from  │  │ iOS 26+ / macOS  │
        │ Whisper     │  │ Swift side)  │  │ 26+ only         │
        │ models      │  │ Qwen3-ASR    │  │ Apple's model    │
        └─────────────┘  └──────────────┘  └──────────────────┘
```

**Note on MLX:** MLX has no Rust bindings. Qwen3-ASR on MLX is called from the Swift frontend, not from the Rust core. The Rust core sends audio to Swift via callback, Swift runs MLX inference, sends result back to Rust for text pipeline. This is the same pattern as calling CoreML from Swift.

### macOS (Intel)

- whisper.cpp CPU (AVX2/SSE optimized) or ONNX Runtime CPU
- No Metal GPU benefit on Intel iGPUs (negligible)
- Recommend Whisper large-v3-turbo or smaller models only
- This is a declining platform — support but don't optimize

### Windows

```
                      ┌──────────────────────┐
                      │  Windows App         │
                      │  Qt 6 (C++)          │
                      └──────────┬───────────┘
                                 │ C FFI
                      ┌──────────▼──────────┐
                      │  hitoku-core (Rust)  │
                      │  Audio + VAD + Text  │
                      └──────────┬──────────┘
                                 │
          ┌──────────────────────┼───────────────────────┐
          ▼                      ▼                        ▼
   ┌──────────────┐    ┌────────────────┐    ┌─────────────────┐
   │ whisper.cpp   │    │ ONNX Runtime   │    │ whisper.cpp     │
   │ CUDA          │    │ DirectML EP    │    │ Vulkan          │
   │               │    │                │    │                 │
   │ NVIDIA GPUs   │    │ AMD + Intel    │    │ Any GPU         │
   │ Best perf     │    │ GPUs           │    │ (fallback)      │
   └───────────────┘    └────────────────┘    └─────────────────┘
```

### iOS

```
                      ┌──────────────────────┐
                      │  iOS App (Swift)     │
                      │  Keyboard Extension  │
                      │  + Settings App      │
                      └──────────┬───────────┘
                                 │ C FFI
                      ┌──────────▼──────────┐
                      │  hitoku-core (Rust)  │
                      │  Audio + VAD + Text  │
                      └──────────┬──────────┘
                                 │
               ┌─────────────────┼──────────────────┐
               ▼                 ▼                   ▼
        ┌────────────┐  ┌───────────────┐  ┌──────────────────┐
        │ CoreML      │  │ ONNX Runtime  │  │ SpeechAnalyzer   │
        │ ANE + GPU   │  │ CoreML EP     │  │ (zero download)  │
        │ Parakeet    │  │ Moonshine     │  │ Apple's model    │
        └─────────────┘  └───────────────┘  └──────────────────┘
```

**Keyboard extension memory limit:** 50MB hard limit. Strategy:
- The keyboard extension itself is thin — just UI and audio capture
- Inference runs in the main app process via an App Group shared container
- Keyboard sends audio chunks to main app via IPC (Darwin notifications + shared memory)
- Main app sends transcribed text back to keyboard for insertion

### Android

```
                      ┌──────────────────────┐
                      │  Android App (Kotlin)│
                      │  IME Service         │
                      │  + Settings Activity │
                      └──────────┬───────────┘
                                 │ JNI → C FFI
                      ┌──────────▼──────────┐
                      │  hitoku-core (Rust)  │
                      │  Audio + VAD + Text  │
                      └──────────┬──────────┘
                                 │
               ┌─────────────────┼──────────────┐
               ▼                 ▼               ▼
        ┌────────────┐  ┌───────────────┐  ┌──────────┐
        │ ONNX Mobile │  │ LiteRT        │  │ whisper  │
        │ NNAPI EP    │  │ GPU delegate  │  │ .cpp CPU │
        │             │  │ (OpenCL)      │  │ (fallback│
        └─────────────┘  └───────────────┘  └──────────┘
```

---

## 7. Audio Pipeline

```
Microphone
    │
    ▼
┌──────────────────────────────────────────────┐
│              Platform Audio Capture           │
│  macOS: AVAudioEngine / CoreAudio             │
│  Windows: WASAPI (via cpal)                   │
│  iOS: AVAudioEngine                           │
│  Android: AAudio / Oboe (via cpal)            │
└──────────────────┬───────────────────────────┘
                   │ Raw PCM (44.1/48 kHz, possibly stereo)
                   ▼
┌──────────────────────────────────────────────┐
│         hitoku-core Audio Engine (Rust)       │
│                                              │
│  1. Format conversion → 16 kHz mono Float32  │
│     (rubato crate for high-quality resample) │
│                                              │
│  2. Ring buffer (10s lookback)               │
│     - Allows re-transcription of recent audio│
│     - Provides context for streaming models  │
│                                              │
│  3. Voice Activity Detection (VAD)           │
│     - Silero VAD v5 (ONNX, 2MB, CPU-only)   │
│     - Detects speech onset → start session   │
│     - Detects silence → end session / chunk  │
│     - Energy-based fallback if ONNX unavail  │
│                                              │
│  4. Chunker (adaptive)                       │
│     - Streaming models: 0.5s chunks          │
│     - Batch models: accumulate until silence │
│     - Max chunk: 30s (Whisper constraint)    │
│                                              │
│  5. Audio queue → Inference Adapter          │
└──────────────────────────────────────────────┘
```

**Audio capture abstraction:**

On macOS/iOS, we use AVAudioEngine directly from Swift (better integration with system audio sessions). On Windows/Android, we use `cpal` from Rust. The Rust core receives audio via `hitoku_feed_audio(samples: *const f32, count: usize, sample_rate: u32)` — the platform layer is responsible for capture.

---

## 8. Streaming Architecture

Two paths, selected automatically by model capability:

### Path A: Native Streaming (Moonshine, Parakeet-TDT)

```
Audio chunk (0.5s) ─► Model processes incrementally ─► Partial result
    ─► Diff against previous partial ─► New tokens ─► Display

Timeline:
  Audio:    [chunk1][chunk2][chunk3][chunk4]...
  Results:  "The"   "The qu" "The quick" "The quick brown"
  Display:  ^live    ^live    ^live       ^live
  Latency:  ~100ms per update
```

- Words appear as you speak — true real-time UX
- Lower accuracy than batch (model sees less context)
- Best for: live preview, short dictation, fast mode

### Path B: Re-transcription (Whisper, Qwen3-ASR)

```
Audio accumulates in ring buffer. Every 0.5-1s:
  Re-transcribe entire buffer from start
  Compare to previous full transcription
  Emit: [stable prefix (won't change)] + [tentative suffix (may change)]
  Display: stable in black, tentative in gray

Timeline:
  Audio:    [──────────growing buffer──────────]
  Pass 1:   "The quik"
  Pass 2:   "The quick brow"
  Pass 3:   "The quick brown fox"
  Stable:   "The quick"  (committed, won't change)
  Tentative: "brown fox"  (may be revised)
  Latency:  ~500ms-1s per update
```

- Higher accuracy (more audio context per pass)
- Higher compute cost (re-processes entire buffer)
- Best for: accurate mode, long dictation, final pass

### Hybrid Mode (Premium UX)

Use both simultaneously for the best user experience:

```
While speaking:
  Path A (Moonshine) → fast live preview (gray text)

After silence detected (VAD):
  Path B (Qwen3-ASR) → high-accuracy final pass
  Replace live preview with final result (black text)

User perceives: instant response + perfect final output
```

This is the key UX differentiator vs. competitors.

---

## 9. Text Pipeline

Post-processing applied to raw STT output. Runs in the Rust core — shared across all platforms.

### Phase 1 (rule-based, no LLM)

```
Raw STT output
    │
    ▼
┌─ 1. Filler Removal ──────────────────────────────┐
│  Strip: "uh" "um" "euh" "ähm" "also" "basically" │
│  Strip: hesitation repeats ("the the the")        │
│  Language-aware: different fillers per locale      │
└───────────────────────────────┬───────────────────┘
                                │
┌─ 2. Punctuation Pass ────────▼───────────────────┐
│  If model outputs punctuation: keep it            │
│  If not: add basic rules (pause → period,         │
│  rising intonation → question mark)               │
└───────────────────────────────┬───────────────────┘
                                │
┌─ 3. Capitalization ──────────▼───────────────────┐
│  Sentence-initial caps                            │
│  Known proper nouns from hot-word list             │
│  Acronyms from hot-word list (ecg → ECG)          │
└───────────────────────────────┬───────────────────┘
                                │
┌─ 4. Number Formatting ──────▼───────────────────┐
│  "twenty three" → "23" (configurable)            │
│  "three point five percent" → "3.5%"             │
│  Locale-aware: "1.000,50" (DE) vs "1,000.50" (EN)│
└───────────────────────────────┬───────────────────┘
                                │
┌─ 5. Hot-Word Substitution ──▼───────────────────┐
│  User-defined vocabulary file:                    │
│  "patient mueller" → "Patient Müller"             │
│  "paracetamol" → "Paracetamol 500mg"             │
│  "article three twenty one" → "Art. 321 StGB"     │
│  Fuzzy matching (Levenshtein distance ≤ 2)        │
└───────────────────────────────┬───────────────────┘
                                │
┌─ 6. Per-App Profile ────────▼───────────────────┐
│  Detect active app (from frontend callback)       │
│  Apply profile: formal/casual/clinical/legal      │
│  Formal: full sentences, proper punctuation       │
│  Casual: lowercase ok, emoji shortcodes           │
│  Clinical: structured note format                 │
└───────────────────────────────┬───────────────────┘
                                │
                                ▼
                          Final text → paste/display
```

### Phase 2 additions (with LLM)

- Grammar correction (on-device LLM pass)
- Sentence restructuring (split run-ons, fix fragments)
- Tone adjustment (formal ↔ casual)
- Domain-specific formatting (SOAP notes, legal citations)

---

## 10. Technology Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **Shared core** | Rust | Memory-safe, no GC, excellent C FFI, cross-compiles to all targets |
| **Audio capture** | cpal (Win/Android), AVAudioEngine (Apple) | Platform-native where it matters, cross-platform elsewhere |
| **Audio resample** | rubato (Rust crate) | High-quality async resampler, no dependencies |
| **VAD** | Silero VAD v5 via ONNX | 2MB model, CPU-only, industry standard, cross-platform |
| **STT: Whisper** | whisper.cpp (C FFI) | Metal+CUDA+Vulkan, battle-tested, widest model support |
| **STT: ONNX models** | ort crate (ONNX Runtime) | DirectML+CoreML+CUDA+QNN, supports Moonshine/Parakeet/Qwen3-ASR |
| **STT: MLX** | mlx-swift or mlx-c (Apple only) | Best Apple Silicon performance for Qwen3-ASR |
| **Model download** | hf-hub crate | HuggingFace Hub download with resume, progress, auth |
| **Desktop frontend** | C++ / Qt 6 (commercial license) | ONE codebase for macOS + Windows + Linux. 31-year track record. |
| **iOS frontend** | Swift + UIKit (keyboard) + SwiftUI (settings) | Keyboard extension requires native. Phase 4. |
| **Android frontend** | Kotlin + Jetpack Compose | IME requires native. Phase 4. |
| **Build: Rust** | Cargo + cargo-xwin (cross-compile) | Standard Rust tooling |
| **Build: Desktop** | CMake + Qt 6 | Qt's CMake integration, one build system for all desktop platforms |
| **CI/CD** | GitHub Actions | macOS, Windows x64, Windows ARM64, Linux x64 runners |
| **Distribution** | Smart installer (web page detects OS → downloads correct build) | See Section 16 |
| **Distribution: iOS** | App Store | Required for keyboard extensions. Phase 4. |
| **Distribution: Android** | Play Store + direct APK | Phase 4. |

---

## 11. Repo Structure

```
hitoku-pro/
├── README.md
├── LICENSE
├── docs/
│   ├── CROSS_PLATFORM_PLAN.md      # This document
│   ├── ARCHITECTURE.md             # Detailed architecture reference
│   └── BUILDING.md                 # Build instructions (extracted from this doc)
│
├── core/                            # Rust shared core
│   ├── Cargo.toml                   # Workspace root
│   ├── Cargo.lock
│   ├── crates/
│   │   ├── hitoku-audio/            # Audio engine: resample, ring buffer, format
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs
│   │   │       ├── resample.rs      # 44.1/48kHz → 16kHz mono
│   │   │       ├── ring_buffer.rs   # Lookback buffer for re-transcription
│   │   │       └── format.rs        # PCM format conversion
│   │   │
│   │   ├── hitoku-vad/              # Voice Activity Detection
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs
│   │   │       ├── silero.rs        # Silero VAD v5 via ONNX
│   │   │       └── energy.rs        # Energy-based fallback VAD
│   │   │
│   │   ├── hitoku-stt/              # SpeechRecognizer trait + backends
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs           # SpeechRecognizer trait definition
│   │   │       ├── types.rs         # Partial, Final, Language, BackendCaps
│   │   │       ├── whisper_cpp.rs   # whisper.cpp C FFI backend
│   │   │       ├── onnx.rs          # ONNX Runtime backend (Moonshine, Parakeet, Qwen3)
│   │   │       └── detect.rs        # Hardware detection + backend selection
│   │   │
│   │   ├── hitoku-text/             # Text post-processing pipeline
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs
│   │   │       ├── filler.rs        # Filler word removal (multilingual)
│   │   │       ├── punctuation.rs   # Punctuation restoration
│   │   │       ├── capitalize.rs    # Capitalization rules
│   │   │       ├── numbers.rs       # Number formatting (locale-aware)
│   │   │       ├── hotwords.rs      # User vocabulary substitution
│   │   │       └── profiles.rs      # Per-app formatting profiles
│   │   │
│   │   ├── hitoku-models/           # Model download & management
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs
│   │   │       ├── download.rs      # HuggingFace Hub download with resume
│   │   │       ├── cache.rs         # Local model cache management
│   │   │       └── verify.rs        # SHA256 integrity check
│   │   │
│   │   ├── hitoku-engine/           # Orchestrator (state machine + pipeline)
│   │   │   ├── Cargo.toml
│   │   │   └── src/
│   │   │       ├── lib.rs
│   │   │       ├── state.rs         # FSM: idle→loading→ready→streaming→draining
│   │   │       ├── pipeline.rs      # Audio → STT → Text Pipeline → Output
│   │   │       ├── config.rs        # Engine configuration
│   │   │       └── hybrid.rs        # Hybrid streaming (fast preview + accurate final)
│   │   │
│   │   └── hitoku-ffi/              # C FFI exports
│   │       ├── Cargo.toml
│   │       ├── src/
│   │       │   └── lib.rs           # extern "C" functions
│   │       ├── hitoku.h             # Generated C header (cbindgen)
│   │       └── cbindgen.toml
│   │
│   └── tests/                       # Integration tests
│       ├── test_audio_pipeline.rs
│       ├── test_stt_backends.rs
│       └── test_text_pipeline.rs
│
├── third-party/                     # Vendored C/C++ dependencies
│   └── whisper.cpp/                 # git submodule
│
├── models/                          # Model metadata (not the weights)
│   ├── moonshine-v2-small.json      # { name, hf_repo, sha256, size, languages }
│   ├── whisper-large-v3-turbo.json
│   ├── qwen3-asr-0.6b.json
│   └── silero-vad-v5.json
│
├── desktop/                         # ALL desktop platforms (Qt 6) — ONE CODEBASE
│   ├── CMakeLists.txt               # Qt 6 CMake project (builds on macOS, Windows, Linux)
│   ├── src/
│   │   ├── main.cpp                 # Entry point, QApplication
│   │   ├── trayicon.cpp/.h          # QSystemTrayIcon + context menu
│   │   ├── hotkeymanager.cpp/.h     # Global hotkey (platform-specific impl)
│   │   ├── hotkeymanager_mac.mm     # macOS: NSEvent global monitor
│   │   ├── hotkeymanager_win.cpp    # Windows: RegisterHotKey
│   │   ├── hotkeymanager_linux.cpp  # Linux: X11 XGrabKey / Wayland
│   │   ├── settingswindow.cpp/.h    # Settings dialog (Qt Widgets)
│   │   ├── overlaywidget.cpp/.h     # Floating transcription overlay
│   │   ├── onboardingwizard.cpp/.h  # First-run: language → model → test
│   │   ├── modelmanager.cpp/.h      # Model download progress UI
│   │   ├── hitokubridge.cpp/.h      # C++ wrapper around hitoku-ffi C API
│   │   ├── clipboardservice.cpp/.h  # QClipboard + platform paste
│   │   ├── pasteservice_mac.mm      # macOS: CGEvent-based paste
│   │   ├── pasteservice_win.cpp     # Windows: SendInput-based paste
│   │   └── pasteservice_linux.cpp   # Linux: xdotool/wtype paste
│   ├── qml/                         # QML for modern UI elements (optional)
│   │   ├── SettingsPage.qml
│   │   └── OverlayContent.qml
│   ├── include/
│   │   └── hitoku.h                 # Generated C header from Rust (cbindgen)
│   ├── platform/                    # Platform-specific resources
│   │   ├── macos/
│   │   │   ├── Info.plist
│   │   │   ├── hitoku.icns
│   │   │   └── HitokuPro.entitlements
│   │   ├── windows/
│   │   │   ├── app.manifest
│   │   │   ├── hitoku.ico
│   │   │   └── hitoku.rc            # Windows resource file (icon, version info)
│   │   └── linux/
│   │       ├── hitoku.desktop       # .desktop launcher file
│   │       ├── hitoku.svg           # Scalable icon
│   │       └── hitoku.appdata.xml   # AppStream metadata
│   └── resources/
│       └── hitoku.qrc               # Qt resource file (shared assets)
│
├── ios/                             # iOS frontend (Phase 4)
│   ├── HitokuPro/                   # Main app (settings, model download)
│   ├── HitokuKeyboard/              # Keyboard extension
│   └── Shared/                      # Shared between app + extension
│
├── android/                         # Android frontend (Phase 4)
│   ├── app/
│   ├── ime/                         # Input Method service
│   └── shared/
│
├── scripts/
│   ├── download_onnxruntime.sh      # Download prebuilt ONNX Runtime binaries
│   ├── download_whisper_cpp.sh      # Update whisper.cpp submodule
│   └── bundle_windows.sh            # Create portable Windows ZIP
│
└── .github/
    └── workflows/
        ├── build-macos.yml
        ├── build-windows.yml
        └── build-all.yml
```

---

## 12. Build Instructions: macOS

### Prerequisites

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin     # Apple Silicon (native)
rustup target add x86_64-apple-darwin      # Intel Mac (cross-compile)

# Xcode command-line tools (needed for C++ compilation on macOS)
xcode-select --install

# Qt 6 (via Homebrew or Qt Online Installer)
brew install qt@6
# Or: download from https://www.qt.io/download

# cbindgen (generate C headers from Rust)
cargo install cbindgen
```

### Build the Rust core

```bash
cd core/

# Build for Apple Silicon (native on your M4)
cargo build --release --target aarch64-apple-darwin

# The output is a static library:
# target/aarch64-apple-darwin/release/libhitoku_ffi.a

# Generate the C header:
cd crates/hitoku-ffi
cbindgen --config cbindgen.toml --crate hitoku-ffi --output hitoku.h
```

### Build the desktop app (Qt — same command on macOS, Windows, Linux)

```bash
cd desktop/

# Copy the Rust header (library is linked via CMake)
cp ../core/crates/hitoku-ffi/hitoku.h include/

# Configure (CMake finds Qt automatically if installed via brew or Qt installer)
cmake -B build -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build --config Release

# Output: build/HitokuPro.app (macOS) or build/HitokuPro (Linux) or build/Release/HitokuPro.exe (Windows)

# On macOS, create a proper .app bundle with Qt frameworks:
macdeployqt build/HitokuPro.app
```

### Universal binary (Apple Silicon + Intel)

```bash
cd core/

# Build for both architectures
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# Create universal static library
lipo -create \
  target/aarch64-apple-darwin/release/libhitoku_ffi.a \
  target/x86_64-apple-darwin/release/libhitoku_ffi.a \
  -output target/universal/libhitoku_ffi.a
```

---

## 13. Build Instructions: Windows

### Option A: Build natively on Windows (recommended for GPU support)

#### Prerequisites (in Windows)

```powershell
# Install Rust
winget install Rustlang.Rustup
rustup target add x86_64-pc-windows-msvc

# Install Visual Studio Build Tools (C++ workload)
winget install Microsoft.VisualStudio.2022.BuildTools
# Select: "Desktop development with C++" workload

# Install CMake
winget install Kitware.CMake

# Install Git
winget install Git.Git

# Install Qt 6 (commercial or open-source)
# Option 1: Qt Online Installer from https://www.qt.io/download
# Option 2: aqtinstall (CLI, faster)
pip install aqtinstall
aqt install-qt windows desktop 6.8.0 win64_msvc2022_64 -m qtmultimedia
# Set environment variable:
# $env:Qt6_DIR = "C:\Qt\6.8.0\msvc2022_64"
```

#### Build the Rust core

```powershell
cd core\

# Build (CPU-only, no CUDA)
cargo build --release --target x86_64-pc-windows-msvc

# Output: target\x86_64-pc-windows-msvc\release\hitoku_ffi.dll
# Output: target\x86_64-pc-windows-msvc\release\hitoku_ffi.lib
```

#### Download ONNX Runtime (prebuilt)

```powershell
# Download DirectML version (supports NVIDIA + AMD + Intel GPUs)
Invoke-WebRequest `
  -Uri "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-win-x64-directml-1.24.4.zip" `
  -OutFile ort.zip
Expand-Archive ort.zip -DestinationPath third-party\onnxruntime

# For CUDA-only (NVIDIA, higher performance):
# Download onnxruntime-win-x64-gpu-1.24.4.zip instead
```

#### Build the Qt desktop app

```powershell
cd desktop-qt\

# Copy Rust library and header
copy ..\core\target\x86_64-pc-windows-msvc\release\hitoku_ffi.dll .
copy ..\core\target\x86_64-pc-windows-msvc\release\hitoku_ffi.lib .
copy ..\core\crates\hitoku-ffi\hitoku.h include\

# Configure with CMake (Qt 6 must be installed, Qt6_DIR set)
cmake -B build -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_PREFIX_PATH="$env:Qt6_DIR" `
  -DORT_ROOT=..\third-party\onnxruntime\onnxruntime-win-x64-directml-1.24.4

# Build
cmake --build build --config Release

# Output: build\Release\HitokuPro.exe
```

#### Create portable bundle

```powershell
mkdir dist
copy build\Release\HitokuPro.exe dist\
copy hitoku_ffi.dll dist\
copy ..\third-party\onnxruntime\onnxruntime-win-x64-directml-1.24.4\lib\onnxruntime.dll dist\
copy ..\third-party\onnxruntime\onnxruntime-win-x64-directml-1.24.4\lib\DirectML.dll dist\

# Deploy Qt dependencies (copies required Qt DLLs + plugins automatically)
windeployqt --release --no-translations dist\HitokuPro.exe

# Models are downloaded at first launch, not bundled
# The dist/ folder is ready to ZIP and share
```

**Note:** `windeployqt` is Qt's deployment tool — it copies all required Qt DLLs
(`Qt6Core.dll`, `Qt6Gui.dll`, `Qt6Widgets.dll`, platform plugins, etc.) into the
dist folder automatically. Total Qt runtime adds ~30-40MB to the bundle.

### Option B: Cross-compile from macOS (CPU-only, for quick iteration)

```bash
# Install cross-compilation tools
cargo install cargo-xwin
brew install llvm
rustup target add x86_64-pc-windows-msvc

# Build Rust core for Windows (CPU-only)
cd core/
cargo xwin build --release --target x86_64-pc-windows-msvc

# Output: target/x86_64-pc-windows-msvc/release/hitoku_ffi.dll

# Note: This builds CPU-only. For CUDA/DirectML, you must build on Windows.
# Note: whisper.cpp cross-compilation works for CPU but not for CUDA/Vulkan.
```

### Option C: Cross-compile for Windows ARM64

```bash
rustup target add aarch64-pc-windows-msvc
cargo xwin build --release --target aarch64-pc-windows-msvc

# Download ARM64 ONNX Runtime:
# onnxruntime-win-arm64-1.24.4.zip from GitHub releases
```

---

## 14. Build Instructions: CI/CD

### GitHub Actions: Windows x64

```yaml
# .github/workflows/build-windows.yml
name: Build Windows x64

on:
  push:
    branches: [main, dev/*]
  workflow_dispatch:

jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive    # for whisper.cpp

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: x86_64-pc-windows-msvc

      - name: Cache Rust build
        uses: actions/cache@v4
        with:
          path: |
            core/target
            ~/.cargo/registry
          key: windows-x64-${{ hashFiles('core/Cargo.lock') }}

      - name: Build Rust core
        working-directory: core
        run: cargo build --release --target x86_64-pc-windows-msvc

      - name: Download ONNX Runtime DirectML
        run: |
          Invoke-WebRequest `
            -Uri "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-win-x64-directml-1.24.4.zip" `
            -OutFile ort.zip
          Expand-Archive ort.zip -DestinationPath ort

      - name: Install Qt 6
        uses: jurplel/install-qt-action@v4
        with:
          version: '6.8.0'
          modules: 'qtmultimedia'

      - name: Build Qt desktop app
        working-directory: desktop-qt
        run: |
          cmake -B build -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH="${{ env.Qt6_ROOT }}"
          cmake --build build --config Release

      - name: Create portable bundle
        run: |
          mkdir dist
          copy desktop-qt\build\Release\HitokuPro.exe dist\
          copy core\target\x86_64-pc-windows-msvc\release\hitoku_ffi.dll dist\
          copy ort\onnxruntime-win-x64-directml-1.24.4\lib\onnxruntime.dll dist\
          copy ort\onnxruntime-win-x64-directml-1.24.4\lib\DirectML.dll dist\
          windeployqt --release --no-translations dist\HitokuPro.exe

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: hitoku-pro-windows-x64
          path: dist/
```

### GitHub Actions: Unified Build Matrix (all platforms in one workflow)

```yaml
# .github/workflows/build-all.yml
name: Build All Platforms

on:
  push:
    branches: [main, dev/*]
  pull_request:
  workflow_dispatch:

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          # ── macOS Apple Silicon ──
          - name: macOS ARM64
            os: macos-14
            rust_target: aarch64-apple-darwin
            qt_arch: clang_64
            artifact: hitoku-pro-macos-arm64
            features: "whisper-cpp,onnx"
            ort_url: ""  # CoreML EP, no separate download

          # ── macOS Intel ──
          - name: macOS x64
            os: macos-13
            rust_target: x86_64-apple-darwin
            qt_arch: clang_64
            artifact: hitoku-pro-macos-x64
            features: "whisper-cpp,onnx"
            ort_url: ""

          # ── Windows x64 ──
          - name: Windows x64
            os: windows-latest
            rust_target: x86_64-pc-windows-msvc
            qt_arch: win64_msvc2022_64
            artifact: hitoku-pro-windows-x64
            features: "whisper-cpp,onnx"
            ort_url: "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-win-x64-directml-1.24.4.zip"

          # ── Windows ARM64 ──
          - name: Windows ARM64
            os: windows-arm64
            rust_target: aarch64-pc-windows-msvc
            qt_arch: win64_msvc2022_arm64
            artifact: hitoku-pro-windows-arm64
            features: "onnx"
            ort_url: "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-win-arm64-1.24.4.zip"

          # ── Linux x64 ──
          - name: Linux x64
            os: ubuntu-latest
            rust_target: x86_64-unknown-linux-gnu
            qt_arch: gcc_64
            artifact: hitoku-pro-linux-x64
            features: "whisper-cpp,onnx"
            ort_url: "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-linux-x64-gpu-1.24.4.tgz"

    runs-on: ${{ matrix.os }}
    name: ${{ matrix.name }}

    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.rust_target }}

      - name: Install Qt 6
        uses: jurplel/install-qt-action@v4
        with:
          version: '6.8.0'
          arch: ${{ matrix.qt_arch }}
          modules: 'qtmultimedia'

      - name: Cache Rust build
        uses: actions/cache@v4
        with:
          path: |
            core/target
            ~/.cargo/registry
          key: ${{ matrix.rust_target }}-${{ hashFiles('core/Cargo.lock') }}

      - name: Build Rust core
        working-directory: core
        run: cargo build --release --target ${{ matrix.rust_target }} --features "${{ matrix.features }}"

      - name: Download ONNX Runtime
        if: matrix.ort_url != ''
        shell: bash
        run: |
          curl -L -o ort-package.zip "${{ matrix.ort_url }}"
          mkdir -p third-party/onnxruntime
          if [[ "${{ matrix.ort_url }}" == *.tgz ]]; then
            tar -xzf ort-package.zip -C third-party/onnxruntime
          else
            unzip ort-package.zip -d third-party/onnxruntime
          fi

      - name: Build Qt desktop app
        working-directory: desktop
        run: |
          cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="${{ env.Qt6_ROOT }}"
          cmake --build build --config Release

      - name: Bundle (macOS)
        if: runner.os == 'macOS'
        run: |
          mkdir -p dist
          cp -R desktop/build/HitokuPro.app dist/
          macdeployqt dist/HitokuPro.app

      - name: Bundle (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          mkdir dist
          copy desktop\build\Release\HitokuPro.exe dist\
          copy core\target\${{ matrix.rust_target }}\release\hitoku_ffi.dll dist\
          Get-ChildItem -Path third-party\onnxruntime -Recurse -Include *.dll | Copy-Item -Destination dist\
          windeployqt --release --no-translations dist\HitokuPro.exe

      - name: Bundle (Linux)
        if: runner.os == 'Linux'
        run: |
          mkdir -p dist
          cp desktop/build/HitokuPro dist/
          cp core/target/${{ matrix.rust_target }}/release/libhitoku_ffi.so dist/
          find third-party/onnxruntime -name "*.so*" -exec cp {} dist/ \;
          # TODO: linuxdeployqt or AppImage packaging

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/
```

This **single workflow** produces 5 builds on every push:
- `hitoku-pro-macos-arm64` (Apple Silicon)
- `hitoku-pro-macos-x64` (Intel Mac)
- `hitoku-pro-windows-x64` (Windows desktop)
- `hitoku-pro-windows-arm64` (Snapdragon laptops)
- `hitoku-pro-linux-x64` (Ubuntu/Fedora/Arch)

---

## 15. Windows Development Environment

### Option A: UTM Virtual Machine (recommended to start)

**Setup:**

1. Download UTM from https://mac.getutm.app/
2. Download Windows 11 ARM ISO:
   - Go to https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewarm64
   - Or use UUP dump (https://uupdump.net/) to build an ISO
3. Create VM in UTM:
   - Backend: Apple Virtualization (not QEMU — much faster on M4)
   - RAM: 8GB minimum, 16GB recommended (you have 48GB, so give it 16)
   - Disk: 80GB minimum (Visual Studio is huge)
   - CPU: 4-6 cores
   - Enable Rosetta (for running x86 tools)

**Install dev tools inside the VM:**

```powershell
# Install Windows Package Manager
# (should be pre-installed on Windows 11)

# Install essentials
winget install Rustlang.Rustup
winget install Kitware.CMake
winget install Git.Git
winget install Microsoft.VisualStudio.2022.Community
# In VS installer: select "Desktop development with C++"

# Install Qt 6
# Download Qt Online Installer from https://www.qt.io/download
# Or use aqtinstall:
pip install aqtinstall
aqt install-qt windows desktop 6.8.0 win64_msvc2022_64 -m qtmultimedia

# Verify
rustc --version
cmake --version
git --version
```

**Limitations of UTM:**
- No GPU acceleration (no DirectML, no Vulkan, no CUDA testing)
- CPU inference works fine
- Good for: Qt/C++ development, UI work, debugging, basic testing
- Not good for: GPU performance testing

**File sharing between Mac and VM:**
- UTM supports shared directories (VirtioFS)
- Map your project folder to a drive letter in the VM
- Or use Git to push/pull between host and VM

### Option B: Cheap Windows PC for GPU testing

For testing GPU acceleration, get a dedicated Windows machine:

- **Budget ($200-300):** Used Dell/Lenovo with NVIDIA GTX 1650+ (CUDA testing)
- **Mid-range ($400-500):** Beelink/MinisForum with AMD Ryzen 7 + Radeon iGPU (DirectML/Vulkan testing)
- **Best value ($500-700):** Mini PC with NVIDIA RTX 3060+ (CUDA + DirectML)

This gives you real GPU testing that a VM cannot provide.

### Option C: Cloud GPU (for CI and occasional testing)

- **GitHub Actions:** Free for public repos, `windows-latest` has no GPU
- **Azure NV-series:** NVIDIA T4 GPU, ~$0.90/hour — good for occasional CUDA testing
- **GitHub Codespaces:** No GPU support currently

### Recommendation

1. **Start with UTM** — develop the Qt frontend, test CPU inference, debug
2. **Use GitHub Actions CI** — automated builds with CUDA/DirectML for releases
3. **Get a cheap Windows PC later** — when you need real GPU testing ($300-500)

---

## 16. Distribution & Smart Installer

### 16.1 CI produces all builds automatically

Every push to `main` triggers the unified CI matrix (Section 14), producing 5 artifacts:

| Artifact | Platform | Size (est.) |
|----------|----------|------------|
| `hitoku-pro-macos-arm64` | macOS Apple Silicon (.app) | ~60MB |
| `hitoku-pro-macos-x64` | macOS Intel (.app) | ~60MB |
| `hitoku-pro-windows-x64` | Windows x64 (.exe + DLLs) | ~100MB |
| `hitoku-pro-windows-arm64` | Windows ARM64 (.exe + DLLs) | ~90MB |
| `hitoku-pro-linux-x64` | Linux x64 (AppImage or tar.gz) | ~80MB |

Models are NOT included — they download on first launch (123MB-3.4GB depending on selection).

### 16.2 Smart installer (download page)

The website (hitoku.me/download or hitokupro.com/download) detects the user's OS and architecture automatically, then shows the right download button:

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│          Download Hitoku Pro                         │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │                                             │   │
│   │   [  Download for macOS (Apple Silicon)  ]  │   │ ← auto-detected
│   │                                             │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Other platforms:                                  │
│   macOS Intel | Windows x64 | Windows ARM |  Linux  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**How OS detection works** (simple JavaScript on the download page):

```javascript
function detectPlatform() {
  const ua = navigator.userAgent;
  const platform = navigator.platform;

  if (/Mac/.test(platform)) {
    // Check for Apple Silicon via WebGL renderer
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl');
    const renderer = gl?.getParameter(gl.RENDERER) || '';
    if (/Apple/.test(renderer)) return 'macos-arm64';
    return 'macos-x64';
  }
  if (/Win/.test(platform)) {
    // ARM64 Windows reports as "Win32" but has specific UA hints
    if (/ARM/.test(ua) || /Qualcomm/.test(ua)) return 'windows-arm64';
    return 'windows-x64';
  }
  if (/Linux/.test(platform)) return 'linux-x64';
  return 'unknown';
}
```

**Download URLs** point to GitHub Releases (free hosting):
```
https://github.com/user/hitoku-pro/releases/latest/download/hitoku-pro-macos-arm64.dmg
https://github.com/user/hitoku-pro/releases/latest/download/hitoku-pro-windows-x64.zip
...etc
```

### 16.3 Package formats per platform

| Platform | Format | Install experience |
|----------|--------|-------------------|
| macOS | `.dmg` (drag to Applications) | Standard Mac experience. Signed + notarized. |
| Windows | `.zip` (portable) or `.msi` (installer) | Portable: unzip and run. MSI: proper Start Menu entry, uninstaller. |
| Linux | AppImage or `.deb` + `.rpm` | AppImage: download, chmod +x, run. Deb/RPM: `apt install` / `dnf install`. |

### 16.4 Quick path: give your friend a build

1. Push code to GitHub
2. CI builds automatically (takes ~15-20 min)
3. Go to Actions → latest build → download `hitoku-pro-windows-x64`
4. Send your friend the ZIP

**What your friend gets:**
```
HitokuPro/
├── HitokuPro.exe          # Qt app (~10MB)
├── hitoku_ffi.dll          # Rust core (~5MB)
├── onnxruntime.dll         # ML runtime (~30-60MB)
├── DirectML.dll            # GPU acceleration (~10MB)
├── Qt6Core.dll             # Qt runtime (~35MB total, auto-deployed)
├── Qt6Gui.dll
├── Qt6Widgets.dll
├── platforms/qwindows.dll
└── styles/                 # Native Windows look
```

**Your friend's experience:**
1. Unzip to any folder
2. Double-click `HitokuPro.exe`
3. First-run wizard: select language → download model (~30 seconds for Moonshine Small)
4. Set global hotkey (e.g., Ctrl+Shift+Space)
5. Hold hotkey → speak → release → text appears in focused field

No admin privileges. No installation. Portable — runs from USB stick.

#### What if you don't have the Qt frontend yet?

For the very first test build, create a **CLI-only version** before the Qt GUI:

```
HitokuPro.exe --model whisper-large-v3-turbo --hotkey ctrl+shift+space
```

The CLI app:
1. Loads the model
2. Listens for the hotkey
3. Captures audio while hotkey is held
4. Transcribes and prints to console (or copies to clipboard)

This lets your friend test STT quality immediately while you build the GUI later.

#### Alternative: Build in UTM

If GitHub CI isn't set up yet:

```powershell
# In your UTM Windows VM:
git clone https://github.com/yourusername/hitoku-pro.git
cd hitoku-pro\core
cargo build --release

# Create bundle
mkdir ..\dist
copy target\release\hitoku_ffi.dll ..\dist\
# ... (build Windows app, copy DLLs)

# ZIP the dist folder and share via AirDrop, email, or cloud storage
```

---

## 17. Mobile Strategy (iOS & Android)

### iOS Architecture

**Two components:**
1. **Main app** — Settings, model download, file transcription, onboarding
2. **Keyboard extension** — System-wide dictation in any text field

**Keyboard extension challenge:** Apple limits keyboard extensions to 50MB memory. Strategy:
```
┌─ Keyboard Extension (< 50MB) ─────────────┐
│  UI only: mic button, live text preview     │
│  Captures audio via AVAudioEngine           │
│  Sends audio chunks to main app via IPC     │
│  Receives text back, inserts into text field│
└─────────────────┬──────────────────────────┘
                  │ App Group + shared memory
┌─────────────────▼──────────────────────────┐
│  Main App Process                          │
│  hitoku-core (Rust) + CoreML inference      │
│  Full model loaded, no memory limit         │
│  Processes audio, returns transcribed text   │
└────────────────────────────────────────────┘
```

**SpeechAnalyzer (iOS 26+):** Offered as an optional "zero-download quick start" backend. Not the primary engine — it's a black box with no custom vocabulary. Users who need premium accuracy switch to our custom models.

### Android Architecture

**Two components:**
1. **Main app** — Settings, model download, file transcription
2. **IME service** — Input Method Editor for system-wide dictation

Android IMEs have more generous memory limits than iOS keyboard extensions. The Rust core can run directly in the IME process.

```
┌─ IME Service ──────────────────────────────┐
│  Kotlin UI: mic button, live preview        │
│  Audio capture via Oboe/AAudio              │
│  hitoku-core (Rust) via JNI                 │
│  ONNX Runtime Mobile for inference          │
│  Inserts text into any app's text field     │
└────────────────────────────────────────────┘
```

### Mobile Model Tiers

| Device RAM | Default Model | Size | Quality |
|-----------|---------------|------|---------|
| 3-4 GB (iPhone SE, budget Android) | Moonshine v2 Tiny | 27MB | Good |
| 6-8 GB (iPhone 15, mid Android) | Moonshine v2 Small | 123MB | Better |
| 8+ GB (iPhone 15 Pro+, flagship Android) | Parakeet-TDT 0.6B | 700MB | Best mobile |

### Mobile-Specific Constraints

- **Battery:** STT inference is GPU-intensive. Must pause when battery < 10%. Show battery impact in settings.
- **Thermal:** Sustained inference causes thermal throttling. Monitor device temperature, reduce model quality if overheating.
- **Background:** iOS kills background processes aggressively. Keyboard extension only runs when keyboard is visible — no background drain.
- **App size:** App Store limit is 200MB. Models download separately. Core app (without models) should be < 30MB.
- **Audio sessions:** Handle interruptions (calls, Bluetooth changes, other apps taking audio) gracefully.

---

## 18. Development Roadmap

### Phase 1A: Rust Core Foundation (Weeks 1-4)

**Goal:** Rust core with whisper.cpp backend, working on macOS via CLI

- [ ] Set up `hitoku-pro` repo with workspace structure
- [ ] Implement `hitoku-audio`: resample (rubato), ring buffer, format conversion
- [ ] Implement `hitoku-vad`: Silero VAD v5 via ONNX Runtime
- [ ] Implement `hitoku-stt`: `SpeechRecognizer` trait + whisper.cpp backend (Metal)
- [ ] Implement `hitoku-text`: filler removal, basic punctuation pass-through
- [ ] Implement `hitoku-engine`: state machine, pipeline orchestration
- [ ] Implement `hitoku-ffi`: C FFI with cbindgen
- [ ] CLI demo: `hitoku-cli --model whisper-large-v3-turbo` (macOS, record → transcribe → print)
- [ ] Integration tests with sample audio files

**Deliverable:** A CLI tool that records from microphone and prints transcribed text.

### Phase 1B: macOS App Integration (Weeks 5-8)

**Goal:** macOS menu bar app using Rust core

- [ ] Swift bridge: `HitokuBridge.swift` wrapping C FFI
- [ ] Audio capture via AVAudioEngine → `hitoku_feed_audio()`
- [ ] Menu bar app with hold-to-talk hotkey
- [ ] Live streaming preview (Path B: re-transcription)
- [ ] Paste transcribed text into focused text field
- [ ] Settings UI: model selection, hotkey, language
- [ ] Model download manager (HuggingFace Hub)
- [ ] ONNX Runtime backend for Moonshine v2 (true streaming, Path A)
- [ ] Hybrid mode: Moonshine preview + Whisper final pass

**Deliverable:** Functional macOS dictation app, comparable to SuperWhisper.

### Phase 1C: Windows Port (Weeks 9-12)

**Goal:** Same quality on Windows

- [ ] Cross-compile Rust core for Windows x64
- [ ] whisper.cpp CUDA backend (NVIDIA)
- [ ] ONNX Runtime DirectML backend (AMD/Intel)
- [ ] Qt 6 system tray application (QSystemTrayIcon + QAction menu)
- [ ] Global hotkey (QShortcut + native RegisterHotKey)
- [ ] Clipboard paste into focused window (QClipboard + SendInput)
- [ ] Live transcription overlay widget (frameless QWidget)
- [ ] Qt settings dialog (model selection, hotkey, language)
- [ ] GitHub Actions CI for Windows builds
- [ ] Test on NVIDIA, AMD, Intel GPUs
- [ ] Create portable ZIP bundle (windeployqt + DLLs)

**Deliverable:** Windows ZIP your friend can run and test.

### Phase 1D: Polish & Quality (Weeks 13-16)

**Goal:** Production-ready STT product

- [ ] Qwen3-ASR backend (ONNX export, highest accuracy tier)
- [ ] Hardware auto-detection and backend selection
- [ ] Custom vocabulary / hot-word system
- [ ] Per-app profiles (detect active app)
- [ ] Number formatting (locale-aware)
- [ ] Onboarding wizard (language → model → test)
- [ ] Auto-update (Sparkle on macOS, Qt Installer Framework or built-in on Windows)
- [ ] Memory optimization (unload after inactivity)
- [ ] Performance benchmarking across hardware
- [ ] Qt UI polish: native theme, DPI scaling, dark mode
- [ ] Beta testing with target users (lawyers/doctors)

**Deliverable:** Beta-ready product for macOS + Windows.

### Phase 2: LLM Polish (Weeks 17-24)

- [ ] LLM inference backend (ONNX/GGUF cross-platform)
- [ ] Text cleanup pipeline
- [ ] Voice edit mode
- [ ] Draft mode
- [ ] Domain prompt templates

### Phase 3: Transcription Toolkit (Weeks 25-32)

- [ ] File transcription UI
- [ ] Speaker diarization
- [ ] Export formats (SRT, VTT, DOCX)
- [ ] Transcript archive with search

### Phase 4: Mobile (Weeks 33-40)

- [ ] iOS keyboard extension + main app
- [ ] Android IME + main app
- [ ] Mobile model tiering
- [ ] App Store / Play Store submission

---

## 19. Risks & Mitigations

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|-----------|------------|
| 1 | whisper.cpp API breaks on update | Breaks Rust bindings | Medium | Pin to specific release via git submodule. Wrap in thin abstraction — only 5 C functions exposed. |
| 2 | ONNX Runtime version conflicts between backends | Crashes on some hardware | Medium | Use `load-dynamic` linking — ship exact DLL version. Test matrix in CI. |
| 3 | GPU detection fails on exotic hardware | Falls back to CPU (slow) | Low | Graceful degradation: always have CPU fallback. Log detection for diagnostics. |
| 4 | Medical German vocabulary accuracy too low | Doctors reject product | High | Partner with medical transcription evaluators for test data. Fine-tune Whisper on medical German corpus if needed. Offer hot-word system as interim fix. |
| 5 | Rust ↔ Swift FFI complexity | Slow macOS development | Medium | Keep FFI surface minimal (~15 functions). Use cbindgen for automatic header generation. Test FFI layer separately. |
| 6 | Qt commercial license cost | $4K+/year ongoing | Low | Budget as cost of doing business. Alternative: LGPL with dynamic linking (free, just ship Qt DLLs separately). |
| 7 | iOS keyboard extension memory limit | Can't run model in extension | Low | Already mitigated: model runs in main app process, keyboard extension is UI-only + IPC. |
| 8 | Qwen3-ASR ONNX export doesn't work | Lose best accuracy tier | Medium | Maintain whisper.cpp as primary. Explore sherpa-onnx pre-packaged Qwen3-ASR. |
| 9 | Cross-compilation breaks with C++/Qt deps | Can't build Windows from Mac | High | Use GitHub Actions native Windows builds. Cross-compile only the Rust-pure portions. Qt must be built natively. |
| 10 | Model download fails behind corporate proxy | Broken first-run for enterprise | Medium | Support HTTP proxy config. Offer manual model download (USB/network share). |

---

## 20. Success Metrics

### Phase 1 Launch Criteria

| Metric | Target | How to Measure |
|--------|--------|---------------|
| Word Error Rate (English) | < 6% | Test against LibriSpeech clean + Earnings-22 |
| Word Error Rate (German) | < 8% | Test against CommonVoice DE + custom medical set |
| Word Error Rate (French) | < 8% | Test against CommonVoice FR |
| First-word latency (streaming) | < 200ms | Measure from speech onset to first character displayed |
| Final result latency | < 2s after end of speech | Measure from silence detection to final text |
| Peak memory (STT only) | < 2GB with largest model | Monitor RSS during 10-min session |
| Startup to ready | < 3s (model pre-cached) | Cold start timing |
| Session reliability | 0 crashes in 8-hour day | Beta tester reports |
| Platform coverage | macOS AS, macOS Intel, Win x64 | CI green on all targets |
| GPU coverage | Metal, CUDA, DirectML, Vulkan | Benchmark suite per GPU |

### Business Metrics (6 months post-launch)

| Metric | Target |
|--------|--------|
| Paid users | 500+ |
| Retention (30-day) | > 60% |
| Net Promoter Score | > 50 |
| Support tickets/user/month | < 0.5 |
| Revenue | $10K+ MRR |

---

## 21. Open Questions

1. **Brand:** "Hitoku Pro"? "Hitoku Draft Pro"? Entirely new name for the cross-platform product?
2. **Pricing:** Subscription vs. lifetime vs. hybrid? Universal license or per-platform?
3. **macOS Intel:** Worth supporting? Only ~15% of Mac market, shrinking fast. CPU-only path is cheap to maintain.
4. **Linux:** The Rust core makes it trivial. GTK or Qt frontend. Worth adding to Phase 1?
5. **Fine-tuning pipeline:** Should we offer users a way to fine-tune models on their own accent/vocabulary?
6. **sherpa-onnx:** Use it as a higher-level wrapper over ONNX Runtime (includes pre-packaged models, C API), or go direct with the `ort` Rust crate for more control?
7. **Qt Widgets vs QML:** Use Qt Widgets (traditional, battle-tested, native look) or QML (modern, declarative, custom look)? Or hybrid — Widgets for settings, QML for overlay?
8. **Model format:** Standardize on ONNX for all models, or support multiple formats (ONNX + GGUF + CoreML)?
9. **Offline-first model delivery:** For enterprise, offer USB-based model deployment instead of internet download?
10. **Privacy certification:** Pursue SOC 2 Type II or ISO 27001 certification to compete with enterprise tools?

---

## Appendices

### Appendix A: FFI Surface (hitoku-ffi)

```c
// hitoku.h — generated by cbindgen from Rust

typedef struct HitokuEngine HitokuEngine;

typedef struct HitokuConfig {
    const char* model_path;       // Path to model directory
    const char* language;         // "auto", "en", "de", "fr", "it"
    uint32_t sample_rate;         // Input audio sample rate (we resample internally)
    bool enable_vad;              // Voice activity detection
    bool enable_streaming;        // Emit partial results
    const char* hotwords_path;    // Path to custom vocabulary file (nullable)
    const char* profile;          // "formal", "casual", "clinical" (nullable)
} HitokuConfig;

typedef struct HitokuResult {
    const char* text;             // Transcribed text (UTF-8)
    bool is_final;                // true = final result, false = partial/volatile
    float confidence;             // 0.0-1.0
    const char* language;         // Detected language code
} HitokuResult;

typedef void (*HitokuResultCallback)(const HitokuResult* result, void* user_data);
typedef void (*HitokuStateCallback)(int32_t state, void* user_data);
typedef void (*HitokuProgressCallback)(float progress, void* user_data);

// Lifecycle
HitokuEngine* hitoku_init(const HitokuConfig* config);
void hitoku_destroy(HitokuEngine* engine);

// Model management
int32_t hitoku_load_model(HitokuEngine* engine, const char* model_id);
int32_t hitoku_unload_model(HitokuEngine* engine);
int32_t hitoku_download_model(HitokuEngine* engine, const char* model_id,
                               HitokuProgressCallback cb, void* user_data);

// Audio input
int32_t hitoku_feed_audio(HitokuEngine* engine, const float* samples,
                           uint32_t count, uint32_t sample_rate);

// Session control
int32_t hitoku_start_session(HitokuEngine* engine);
int32_t hitoku_stop_session(HitokuEngine* engine);  // triggers draining
int32_t hitoku_cancel_session(HitokuEngine* engine); // discard

// Callbacks
void hitoku_set_result_callback(HitokuEngine* engine,
                                 HitokuResultCallback cb, void* user_data);
void hitoku_set_state_callback(HitokuEngine* engine,
                                HitokuStateCallback cb, void* user_data);

// Queries
int32_t hitoku_get_state(const HitokuEngine* engine);
const char* hitoku_get_supported_models(void);  // JSON array
const char* hitoku_get_backend_info(const HitokuEngine* engine);  // JSON
```

### Appendix B: Hot-Word File Format

```json
// ~/.hitoku/hotwords.json (or per-profile)
{
  "version": 1,
  "entries": [
    {
      "spoken": "ecg",
      "written": "ECG",
      "case_sensitive": true
    },
    {
      "spoken": "patient mueller",
      "written": "Patient Müller",
      "case_sensitive": true
    },
    {
      "spoken": "article three twenty one",
      "written": "Art. 321 StGB",
      "case_sensitive": true
    },
    {
      "spoken": "paracetamol five hundred",
      "written": "Paracetamol 500mg",
      "case_sensitive": true
    }
  ]
}
```

### Appendix C: Competitive Pricing Research

| Product | Model | Price | Notes |
|---------|-------|-------|-------|
| Wispr Flow Pro | Subscription | $15/mo ($12/mo annual) | Cloud-only |
| Wispr Flow Teams | Per-seat | $12/user/mo ($10 annual) | 3-seat minimum |
| SuperWhisper Pro | Lifetime | $249.99 | On-device |
| SuperWhisper | Subscription | $8.49/mo | On-device |
| Dragon Professional | One-time | $699.99 | Windows only, abandoned |
| Dragon Legal | One-time | $699.99+ | Windows only |
| Otter.ai Pro | Subscription | $16.99/user/mo | Cloud, English-focused |
| **Hitoku Pro (proposed)** | **Subscription** | **$25/mo ($20/mo annual)** | **On-device, cross-platform** |
| **Hitoku Pro (proposed)** | **Lifetime** | **$349** | **One-time purchase option** |
| **Hitoku Pro Enterprise** | **Per-seat** | **$20/user/mo** | **5+ seats, admin console** |

### Appendix D: GPU Backend Coverage Matrix

| Backend | macOS Metal | macOS CPU | Win CUDA | Win DirectML | Win Vulkan | Win ARM/NPU | iOS CoreML | Android NNAPI |
|---------|-----------|-----------|----------|-------------|------------|-------------|------------|---------------|
| whisper.cpp | Yes | Yes | Yes | No | Yes | CPU only | No | No |
| ONNX Runtime | CoreML EP | Yes | Yes | Yes | No | QNN EP | CoreML EP | Yes |
| MLX | Yes | No | No | No | No | No | No | No |
| LiteRT | Metal | Yes | OpenCL | No | No | Yes | Metal | Yes |
| sherpa-onnx | Via ONNX | Yes | Yes | Yes | No | Via ONNX | Via ONNX | Via ONNX |

### Appendix E: Estimated Binary Sizes

| Component | macOS | Windows | iOS | Android |
|-----------|-------|---------|-----|---------|
| App binary (without models) | ~15MB | ~10MB | ~12MB | ~8MB |
| hitoku-core (Rust) | ~5MB | ~5MB | ~5MB | ~5MB |
| Qt 6 runtime | — | ~35MB | — | — |
| ONNX Runtime | ~30MB | ~30MB (DirectML: ~60MB) | ~15MB | ~15MB |
| whisper.cpp | Included in core | Included in core | — | — |
| **Total (no models)** | **~50MB** | **~80-110MB** | **~32MB** | **~28MB** |
| Moonshine v2 Small model | 123MB | 123MB | 123MB | 123MB |
| Whisper large-v3-turbo model | 1.6GB | 1.6GB | — | — |
| Silero VAD | 2MB | 2MB | 2MB | 2MB |
