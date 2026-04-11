# Hitoku Draft

A context aware native macOS menu bar AI assistant. 

Everything runs locally on Apple Silicon. No cloud calls.

Hold to talk. Ask it for email drafting, or understanding a PDF, or set up a calendar meeting.

Download here https://hitoku.me/draft/ or compile yourself.

## Features

- **Context Awareness** — Reads surrounding screen context (active app, selected text, document content) to produce better results.
- **Draft Mode** — Generate new content from voice ("draft an email declining the meeting") — pastes at cursor.
- **Voice Edit** — Select text, press a hotkey, speak an instruction ("make this more formal", "translate to Spanish"), and the text is rewritten in-place.
- **Grammar Fix** — One-hotkey grammar and spelling correction with automatic language detection (English, Italian, French, German, and more).
- **Continuous Dictation** — Real-time speech-to-text with optional LLM polish (filler removal, punctuation).
- **Action Mode** — Voice-triggered actions: set timers, create calendar events, send emails, take notes.
- **Web Search & Tools** — LLM can search the web, fetch URLs, and query your calendar to answer questions.
- **Multiple STT Backends** — Parakeet TDT (CoreML), Qwen3-ASR (streaming MLX), WhisperKit (Whisper tiny/base).
- **Multiple LLM Backends** — MLX (Qwen3.5), LiteRT (Gemma 4 with native audio + vision).
- **Text-to-Speech** — Reads results aloud via Kokoro or PocketTTS when the focused element isn't editable.
- **Display Mode** — Shows results in a floating overlay with syntax highlighting, LaTeX math rendering, and code blocks when you're not in a text field.

## Requirements

- macOS 14.0+
- Apple Silicon (M1 or later)
- Xcode 16.0+ (to build from source)
- Microphone and Accessibility permissions

## Building from Source

The project uses [xcodegen](https://github.com/yonaskolb/XcodeGen) to manage the Xcode project:

```bash
# Install xcodegen if you don't have it
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -scheme HitokuDraft -configuration Release build
```

LiteRT dylibs for Gemma 4 support are not included in the repository. To enable LiteRT:

```bash
cd HitokuInference
./setup_litert_libs.sh
```

## Architecture

- **ConversationCoordinator** — Single orchestration center (state machine + pipeline sequencing)
- **Protocol-backed services** — STTService, LLMService, TTSProvider, EditabilityDetector
- **HitokuInference** — Unified inference routing across MLX and LiteRT backends
- **AppState enum** — Single source of truth for all UI state
- **Swift concurrency** — async/await and actors throughout; @MainActor on coordinators

See `docs/SWIFT_REWRITE_BRIEF.md` for the full architecture specification.

## Models

All models are downloaded from HuggingFace on first use — nothing is bundled in the app binary.

| Model | Type | Backend | Size |
|-------|------|---------|------|
| Qwen3.5 0.8B/4B/9B | LLM | MLX | 0.5–6.5 GB |
| Gemma 4 E2B/E4B | LLM (multimodal) | LiteRT | 2.6–3.7 GB |
| Parakeet TDT v3 | STT | CoreML | 0.6 GB |
| Qwen3-ASR 0.6B/1.7B | STT (streaming) | MLX | 0.8–3.4 GB |
| Whisper tiny/base | STT | WhisperKit | 0.09–0.18 GB |

## Acknowledgments

See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md) for the full list of open-source libraries, AI models, and their licenses.

## License

See [LICENSE](LICENSE) for details.
