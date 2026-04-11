# Acknowledgments & Third-Party Licenses

Hitoku Draft is a commercial macOS application built on open-source software and open-weight AI models. All components are compatible with commercial distribution under the terms described below.

---

## Swift Libraries (bundled in the app)

### FluidAudio
- **Source:** [github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) (remote SPM dependency)
- **License:** Apache 2.0
- **Used for:** Speech-to-text (ASR) via Parakeet TDT v3 CoreML model, voice activity detection, silence detection

### HitokuInference
- **Source:** Local package — `HitokuInference/`
- **License:** Proprietary (part of this project)
- **Used for:** Unified inference routing across MLX and LiteRT backends, multimodal input handling (text, audio, image)

### LiteRT-LM (runtime dylibs)
- **Source:** [ai.google.dev/edge/litert](https://ai.google.dev/edge/litert)
- **License:** Apache 2.0
- **By:** Google
- **Used for:** On-device multimodal inference engine for Gemma 4 models. Dylibs (`liblitert_lm_engine.dylib`, `libLiteRt.dylib`, `libLiteRtMetalAccelerator.dylib`) are bundled in the app Frameworks directory.
- **Note:** Not included in the git repository. Downloaded separately via `setup_litert_libs.sh`.

### mlx-swift-lm
- **Source:** [github.com/ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (remote SPM dependency)
- **License:** MIT — Copyright © 2024 ml-explore
- **Used for:** LLM loading (`MLXLLM`, `MLXLMCommon`), model factory, generation pipeline

### mlx-swift — v0.30.6
- **Source:** [github.com/ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift)
- **License:** MIT — Copyright © 2024 ml-explore
- **Used for:** Core Apple Silicon tensor operations underlying all LLM inference

### KeyboardShortcuts — v2.4.0
- **Source:** [github.com/sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- **License:** MIT — Copyright © Sindre Sorhus
- **Used for:** Global hotkey registration (voice edit, dictation, grammar fix triggers)

### mlx-audio-swift — v0.1.1
- **Source:** [github.com/Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- **License:** MIT
- **Used for:** Audio speech-to-text (MLXAudio, MLXAudioSTT) for on-device transcription via Qwen3-ASR models

### WhisperKit
- **Source:** [github.com/argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit)
- **License:** MIT — Copyright © 2024 Argmax, Inc.
- **Used for:** CoreML/ANE speech recognition for Whisper Tiny and Whisper Base (English-only models)

### swift-huggingface — v0.8.1
- **Source:** [github.com/huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface)
- **License:** Apache 2.0
- **Used for:** HuggingFace Hub client for model downloads

### SwiftMath
- **Source:** [github.com/mgriebling/SwiftMath](https://github.com/mgriebling/SwiftMath)
- **License:** MIT — Copyright © 2022 Mike Griebling (fork of iosMath by Kostub Deshmukh, MIT)
- **Used for:** LaTeX math rendering in the overlay — CoreText/CoreGraphics, no WebKit dependency

### Sparkle — v2.9.0
- **Source:** [github.com/sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
- **License:** MIT — Copyright © 2006-2013 Andy Matuschak, 2015-2024 Sparkle Project
- **Used for:** Auto-update framework (check for updates, download and install new versions)

### CodeHighlighter (built-in)
- **Source:** `VoiceEditor/Views/CodeHighlighter.swift` — original code, part of this project
- **License:** N/A (proprietary, not a separate open-source component)
- **Used for:** Syntax highlighting for code blocks in the overlay. Pure Swift, no external dependencies. Atom One Dark palette; supports Python, Swift, JavaScript/TypeScript, Go, Rust, C/C++, Bash, SQL, JSON, and more.

---

## Transitive Dependencies (indirect, pulled in automatically)

All are Apache 2.0 unless noted otherwise.

| Package | Version | License | Source |
|---|---|---|---|
| async-http-client | 1.32.0 | Apache 2.0 | github.com/swift-server/async-http-client |
| swift-algorithms | 1.2.1 | Apache 2.0 | github.com/apple/swift-algorithms |
| swift-async-algorithms | 1.1.3 | Apache 2.0 | github.com/apple/swift-async-algorithms |
| swift-atomics | 1.3.0 | Apache 2.0 | github.com/apple/swift-atomics |
| swift-certificates | 1.18.0 | Apache 2.0 | github.com/apple/swift-certificates |
| swift-collections | 1.4.0 | Apache 2.0 | github.com/apple/swift-collections |
| swift-crypto | 4.2.0 | Apache 2.0 | github.com/apple/swift-crypto |
| swift-http-types | 1.5.1 | Apache 2.0 | github.com/apple/swift-http-types |
| swift-jinja | 2.3.2 | Apache 2.0 | github.com/huggingface/swift-jinja |
| swift-log | 1.10.1 | Apache 2.0 | github.com/apple/swift-log |
| swift-nio | 2.95.0 | Apache 2.0 | github.com/apple/swift-nio |
| swift-nio-ssl | 2.36.0 | Apache 2.0 | github.com/apple/swift-nio-ssl |
| swift-numerics | 1.1.1 | Apache 2.0 | github.com/apple/swift-numerics |
| swift-system | 1.6.4 | Apache 2.0 | github.com/apple/swift-system |
| swift-transformers | 1.1.9 | Apache 2.0 | github.com/huggingface/swift-transformers |
| EventSource | 1.4.1 | MIT | github.com/mattt/EventSource |
| swift-xet | 0.2.3 | MIT | github.com/mattt/swift-xet |
| yyjson | 0.12.0 | MIT | github.com/ibireme/yyjson |

---

## AI Models (downloaded at runtime, not bundled)

Models are downloaded on first launch from HuggingFace and cached locally. They are not embedded in the app binary or DMG.

### Speech Recognition (STT)

#### NVIDIA Parakeet TDT 0.6B v3 (CoreML)
- **HuggingFace repo:** [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- **Original model:** [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- **License:** CC BY 4.0 — Attribution required, commercial use permitted
- **Used for:** All speech-to-text transcription (25 European languages)
- **Attribution required:** "Parakeet TDT 0.6B v3 by NVIDIA, licensed under CC BY 4.0"

#### OpenAI Whisper tiny.en / base.en
- **Original model:** [openai/whisper](https://github.com/openai/whisper)
- **License:** MIT — Commercial use permitted
- **By:** OpenAI
- **Used for:** Lightweight English-only speech recognition via WhisperKit (CoreML/ANE)

#### Qwen3-ASR 0.6B / 1.7B
- **HuggingFace repos:** [mlx-community/Qwen3-ASR-0.6B-6bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-6bit), [mlx-community/Qwen3-ASR-1.7B-bf16](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16)
- **Original model:** [Qwen/Qwen3-ASR](https://huggingface.co/collections/Qwen/qwen3-asr)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** Alibaba Cloud (Qwen Team)
- **Used for:** Native streaming speech recognition with multilingual support

### Language Models (LLM)

#### Qwen3.5 0.8B / 4B / 9B 4-bit
- **HuggingFace repos:** [mlx-community/Qwen3.5-0.8B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit), [mlx-community/Qwen3.5-4B-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit), [mlx-community/Qwen3.5-9B-4bit](https://huggingface.co/mlx-community/Qwen3.5-9B-4bit)
- **Original models:** [Qwen/Qwen3.5](https://huggingface.co/collections/Qwen/qwen35)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** Alibaba Cloud (Qwen Team)

#### Google Gemma 4 E2B / E4B (LiteRT)
- **HuggingFace repos:** [litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm), [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm)
- **Original models:** [google/gemma-4](https://ai.google.dev/gemma)
- **License:** Gemma Terms of Use — Commercial use permitted
- **By:** Google DeepMind
- **Used for:** Native multimodal inference (audio + vision) via LiteRT on Apple Silicon
- **Note:** The Gemma license permits commercial use but requires accepting Google's Terms of Use.

---

## Compliance Checklist

For direct distribution of a paid app, the following is required:

- [x] **Apache 2.0 libraries** — Include their license texts in app or documentation. A bundled `ACKNOWLEDGMENTS.md` (this file) or in-app Acknowledgments screen satisfies this.
- [x] **MIT libraries** — Same requirement: include license text + copyright notice.
- [x] **Parakeet TDT (CC BY 4.0)** — Must credit NVIDIA in your app's About screen or documentation.
- [x] **Gemma 4 (Gemma Terms of Use)** — Requires acceptance of Google's terms; commercial use permitted.
- [x] **WhisperKit / Whisper (MIT)** — Standard MIT attribution.
- [x] **Qwen3.5 / Qwen3-ASR (Apache 2.0)** — Standard Apache attribution.

### Recommended: Add an Acknowledgments screen

A simple in-app "Acknowledgments" window listing all libraries and their licenses is the cleanest way to satisfy all Apache 2.0, MIT, and CC BY 4.0 attribution requirements in one place.

---

## Inspiration

Hitoku Draft was inspired by the broader community of open-source voice and dictation tools — projects like [Whisper Transcription](https://github.com/Bradleycorn/Whisper-Transcription), [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper), [Aiko](https://github.com/nicklama/aiko), and others that demonstrated how powerful local speech-to-text can be on the Mac. We're grateful to these developers for paving the way and sharing their work.

---

*Last updated: April 2026*

---

## Full License Texts

The following license texts apply to the open-source components listed above. Including these texts satisfies the attribution requirements of the MIT and Apache 2.0 licenses.

### MIT License

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Apache License, Version 2.0

```
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### Creative Commons Attribution 4.0 International (CC BY 4.0)

The NVIDIA Parakeet TDT 0.6B v3 model is licensed under CC BY 4.0.
Attribution: "Parakeet TDT 0.6B v3 by NVIDIA, licensed under CC BY 4.0"
Full license: https://creativecommons.org/licenses/by/4.0/legalcode
