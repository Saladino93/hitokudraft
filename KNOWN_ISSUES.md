# Known Issues — v1.6.3 (litert branch)

## Overlay

1. ~~**Esc key doesn't dismiss overlay reliably**~~ — **Fixed (2026-04-11).**

2. ~~**Ctrl+Z double-press doesn't cancel cleanly**~~ — **Fixed (2026-04-12).** Ctrl+Z now cancels during `.generating` and `.transcribing` states, not just `.listening`.

3. ~~**Ctrl+S dictation overlay appears late**~~ — **Fixed (2026-04-11).**

4. ~~**Overlay jumps between screens on multi-monitor**~~ — **Fixed (2026-04-11).**

5. ~~**Overlay pill is too large/empty in Done state**~~ — **Fixed (2026-04-11).**

## "Allow Vision" Toggle

6. ~~**Race condition when toggling "Allow vision"**~~ — **Fixed (2026-04-12).** Vision toggle now routes through `coordinator.switchModel()`.

## LiteRT / Gemma 4

> **2026-06-04 — Migrated to the official LiteRT-LM Swift SDK (v0.13.1).** The
> hand-rolled `dlopen`/`dlsym` C bridge and the 6 manually-bundled dylibs are
> gone, replaced by the SwiftPM `LiteRTLM` package (prebuilt, checksummed
> `CLiteRTLM_mac.xcframework`). Builds clean and the app launches/links against
> the new engine. **Items 7–8 below need re-measurement on the new engine** —
> the migration pulls a much newer native build than the old ~0.11-era dylibs.

7. **LiteRT WebGPU memory spikes (needs re-test on v0.13.1)** — On the old
   vendored dylibs, the WebGPU backend allocated up to 10× the model weight
   size in Metal buffers (39 GB observed on 48 GB machine, E4B 3.4 GB model).
   See [LiteRT issue #5706](https://github.com/google-ai-edge/LiteRT/issues/5706).
   **Unverified on the official v0.13.1 engine** — pending a Gemma E4B load +
   dictation run with Activity Monitor / `xctrace`.

8. **LiteRT WebGPU deallocation crash (needs re-test on v0.13.1)** —
   `dawn::SlabAllocatorImpl::Deallocate` crashed after generation on the old
   dylibs. Unverified on v0.13.1. Workaround if it recurs: use MLX models (Qwen3.5).

9. **No live transcription with Gemma 4 audio-direct** — By design (only waveform shown).

10. ~~**App size: 146 MB — LiteRT dylibs add ~98 MB, bundled manually**~~ —
    **Resolved (2026-06-04).** Dylibs replaced by the official SDK's xcframework,
    embedded automatically by SwiftPM. No more `Libraries/macos_arm64`, no manual
    "Embed LiteRT Dylibs" build phase.

## General

11. ~~**Swift 6 concurrency warnings — NSLock in LiteRTInferenceBackend**~~ —
    **Resolved (2026-06-04).** All mutable state moved behind a synchronous
    `Store` holder; concurrent closures capture the `Sendable` store, not `self`.
    Backend now compiles warning-free.

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

*Last updated: 2026-06-04*
