# Acknowledgments & Third-Party Licenses

Hitoku Draft is a commercial macOS application built on open-source software and open-weight AI models. All components are compatible with commercial distribution under the terms described below.

---

## Swift Libraries (bundled in the app)

### FluidAudio
- **Source:** Local vendored copy — `examples/FluidAudio/`
- **Origin:** [github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
- **License:** Apache 2.0
- **Used for:** Speech-to-text (ASR) via Parakeet TDT v3 CoreML model, voice activity detection, silence detection
- **Note:** FluidAudio is actively used. It handles all microphone transcription via `AsrManager` and downloads the Parakeet TDT CoreML model on first launch.

### mlx-swift-lm
- **Source:** Local vendored copy — `examples/mlx-swift-lm/`
- **Origin:** Extracted from [github.com/ml-explore/mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples)
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
- **Used for:** Audio speech-to-text (MLXAudio, MLXAudioSTT) for on-device transcription

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
| swift-configuration | 1.2.0 | Apache 2.0 | github.com/apple/swift-configuration |
| swift-crypto | 4.2.0 | Apache 2.0 | github.com/apple/swift-crypto |
| swift-distributed-tracing | 1.4.1 | Apache 2.0 | github.com/apple/swift-distributed-tracing |
| swift-http-structured-headers | 1.6.0 | Apache 2.0 | github.com/apple/swift-http-structured-headers |
| swift-http-types | 1.5.1 | Apache 2.0 | github.com/apple/swift-http-types |
| swift-jinja | 2.3.2 | Apache 2.0 | github.com/huggingface/swift-jinja |
| swift-log | 1.10.1 | Apache 2.0 | github.com/apple/swift-log |
| swift-nio | 2.95.0 | Apache 2.0 | github.com/apple/swift-nio |
| swift-nio-extras | 1.32.1 | Apache 2.0 | github.com/apple/swift-nio-extras |
| swift-nio-http2 | 1.40.0 | Apache 2.0 | github.com/apple/swift-nio-http2 |
| swift-nio-ssl | 2.36.0 | Apache 2.0 | github.com/apple/swift-nio-ssl |
| swift-nio-transport-services | 1.26.0 | Apache 2.0 | github.com/apple/swift-nio-transport-services |
| swift-numerics | 1.1.1 | Apache 2.0 | github.com/apple/swift-numerics |
| swift-service-context | 1.3.0 | Apache 2.0 | github.com/apple/swift-service-context |
| swift-service-lifecycle | 2.10.1 | Apache 2.0 | github.com/swift-server/swift-service-lifecycle |
| swift-system | 1.6.4 | Apache 2.0 | github.com/apple/swift-system |
| swift-transformers | 1.1.9 | Apache 2.0 | github.com/huggingface/swift-transformers |
| swift-xet | 0.2.3 | MIT | github.com/mattt/swift-xet |
| swift-asn1 | 1.5.1 | Apache 2.0 | github.com/apple/swift-asn1 |
| EventSource | 1.4.1 | MIT | github.com/mattt/EventSource |
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

### Language Models (LLM)

#### Qwen3 4B 4-bit
- **HuggingFace repo:** [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit)
- **Original model:** [Qwen/Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** Alibaba Cloud (Qwen Team)

#### Qwen3 8B 4-bit
- **HuggingFace repo:** [mlx-community/Qwen3-8B-4bit](https://huggingface.co/mlx-community/Qwen3-8B-4bit)
- **Original model:** [Qwen/Qwen3-8B](https://huggingface.co/Qwen/Qwen3-8B)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** Alibaba Cloud (Qwen Team)

#### IBM Granite 4.0 1B 4-bit
- **HuggingFace repo:** [mlx-community/granite-4.0-h-1b-base-4bit](https://huggingface.co/mlx-community/granite-4.0-h-1b-base-4bit)
- **Original model:** [ibm-granite/granite-4.0-h-1b-base](https://huggingface.co/ibm-granite/granite-4.0-h-1b-base)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** IBM Research

#### IBM Granite 4.0 1B 8-bit
- **HuggingFace repo:** [mlx-community/granite-4.0-h-1b-base-8bit](https://huggingface.co/mlx-community/granite-4.0-h-1b-base-8bit)
- **Original model:** [ibm-granite/granite-4.0-h-1b-base](https://huggingface.co/ibm-granite/granite-4.0-h-1b-base)
- **License:** Apache 2.0 — Commercial use permitted
- **By:** IBM Research

#### LFM2.5 1.2B Instruct 4-bit ⚠️
- **HuggingFace repo:** [mlx-community/LFM2.5-1.2B-Instruct-4bit](https://huggingface.co/mlx-community/LFM2.5-1.2B-Instruct-4bit)
- **Original model:** [LiquidAI/LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct)
- **License:** LFM Open License v1.0 (Apache 2.0 base + revenue cap)
- **Commercial use:** Free for companies with < $10M annual revenue. Above that threshold, a paid license from Liquid AI is required.
- **By:** Liquid AI

#### LFM2.5 1.2B Instruct 8-bit ⚠️
- **HuggingFace repo:** [mlx-community/LFM2.5-1.2B-Instruct-8bit](https://huggingface.co/mlx-community/LFM2.5-1.2B-Instruct-8bit)
- **Original model:** [LiquidAI/LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct)
- **License:** LFM Open License v1.0 (Apache 2.0 base + revenue cap)
- **Commercial use:** Free for companies with < $10M annual revenue. Above that threshold, contact [liquid.ai/lfm-license](https://www.liquid.ai/lfm-license).
- **By:** Liquid AI

---

## Compliance Checklist

For direct distribution of a paid app, the following is required:

- [x] **Apache 2.0 libraries** — Include their license texts in app or documentation. A bundled `ACKNOWLEDGMENTS.md` (this file) or in-app Acknowledgments screen satisfies this.
- [x] **MIT libraries** — Same requirement: include license text + copyright notice.
- [x] **Parakeet TDT (CC BY 4.0)** — Must credit NVIDIA in your app's About screen or documentation.
- [ ] **LFM2.5 (LFM1.0)** — Permitted under $10M revenue. Monitor if revenue exceeds threshold; contact Liquid AI for a commercial license if it does. Consider whether to include or remove LFM2.5 from the default model list depending on your risk tolerance.

### Recommended: Add an Acknowledgments screen

A simple in-app "Acknowledgments" window listing all libraries and their licenses is the cleanest way to satisfy all Apache 2.0, MIT, and CC BY 4.0 attribution requirements in one place.

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
