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

---

## Transitive Dependencies (indirect, pulled in automatically)

| Package | Version | License | Source |
|---|---|---|---|
| swift-transformers | 1.1.9 | Apache 2.0 | github.com/huggingface/swift-transformers |
| swift-jinja | 2.3.2 | Apache 2.0 | github.com/huggingface/swift-jinja |
| swift-collections | 1.4.0 | Apache 2.0 | github.com/apple/swift-collections |
| swift-crypto | 4.2.0 | Apache 2.0 | github.com/apple/swift-crypto |
| swift-asn1 | 1.5.1 | Apache 2.0 | github.com/apple/swift-asn1 |
| swift-numerics | 1.1.1 | Apache 2.0 | github.com/apple/swift-numerics |
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

*Last updated: March 2026*
