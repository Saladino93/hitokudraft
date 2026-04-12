# Known Issues — v1.6.3 (litert branch)

## Overlay

1. ~~**Esc key doesn't dismiss overlay reliably**~~ — **Fixed (2026-04-11).**

2. ~~**Ctrl+Z double-press doesn't cancel cleanly**~~ — **Fixed (2026-04-12).** Ctrl+Z now cancels during `.generating` and `.transcribing` states, not just `.listening`.

3. ~~**Ctrl+S dictation overlay appears late**~~ — **Fixed (2026-04-11).**

4. ~~**Overlay jumps between screens on multi-monitor**~~ — **Fixed (2026-04-11).**

5. ~~**Overlay pill is too large/empty in Done state**~~ — **Fixed (2026-04-11).**

## "Allow Vision" Toggle

6. ~~**Race condition when toggling "Allow vision"**~~ — **Fixed (2026-04-12).** Vision toggle now routes through `coordinator.switchModel()`.

## LiteRT / Gemma 4 (CRITICAL)

7. **LiteRT WebGPU memory spikes** — LiteRT's WebGPU backend can allocate up to 10x the model weight size in Metal GPU buffers during inference (39 GB observed on 48 GB machine with E4B 3.7 GB model). Inside Google's prebuilt dylibs — not fixable downstream. See [LiteRT issue #5706](https://github.com/google-ai-edge/LiteRT/issues/5706).

8. **LiteRT WebGPU deallocation crash** — `dawn::SlabAllocatorImpl::Deallocate` crashes after generation completes. Inside `libLiteRtWebGpuAccelerator.dylib`. Workaround: use MLX models (Qwen3.5).

9. **No live transcription with Gemma 4 audio-direct** — By design (only waveform shown).

10. **App size: 146 MB** — LiteRT dylibs add ~98 MB. No official Swift package from Google — dylibs bundled manually.

## General

11. **Swift 6 concurrency warnings** — NSLock in LiteRTInferenceBackend async contexts. Works at runtime.

12. **WhisperKit missing from Package.swift** — Only affects `swift build` (not Xcode).

## MLX Gemma 4 Migration (In Progress)

Active work on `main` branch to run Gemma 4 via MLX instead of LiteRT. Status:

- [x] LiteRT backend fully removed from `main`
- [x] `mlx-swift-lm` pointed at adrgrondin's fork (PR #180 — Gemma 4 text + vision + MoE)
- [x] `mlx-audio-swift` replaced with FluidAudio CoreML Qwen3-ASR
- [x] TokenizerBridge + HubDownloaderBridge replace MLXHuggingFace macros (CLI incompatible)
- [x] Model loads successfully, ~4.5 GB RSS (vs 39 GB LiteRT)
- [ ] **Generation crashes:** `[broadcast_shapes] Shapes (64) and (79) cannot be broadcast` in repetition penalty processor. Upstream bug in mlx-swift-lm Gemma 4 VLM port.
- [ ] **Blocked on:** PR #180 merge + shape bug fix in mlx-swift-lm
- [ ] **Blocked on:** `mlx-audio-swift` updating to mlx-swift-lm 3.x (currently requires 2.x)

When PR #180 is merged and stable, switch `main` to official mlx-swift-lm and ship without LiteRT.

---

## TODO

- [ ] **Ship MLX Gemma 4** — Waiting on upstream mlx-swift-lm PR #180 fix.
- [ ] **Re-enable Qwen3-ASR 1.7B** — Waiting on mlx-audio-swift 3.x compatibility.
- [ ] **Verify vision toggle memory with Instruments** — Confirm no residual GPU buffer leaks.
- [ ] **Remove LiteRT dylibs from app** — Once MLX Gemma 4 is stable, delete litert branch content from releases.

---

*Last updated: 2026-04-12*
