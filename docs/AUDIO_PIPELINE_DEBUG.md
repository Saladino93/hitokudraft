# Audio Pipeline — Debug & Diagnostics Guide

## Previous Failure Mode

Three bugs caused "No audio detected" / "Recording produced no audio" even with a working microphone:

### Bug 1: Shared AVAudioConverter statefulness
A single `AVAudioConverter` was created at engine start and reused for every tap callback buffer. The `convert(to:error:inputBlock:)` API is stateful — after the input block signals `.endOfStream`, the converter enters a terminal state. The first buffer converted correctly; every subsequent buffer silently produced zero frames.

### Bug 2: `copyBuffer` assumed Float32
`guard let srcChannels = source.floatChannelData` returns `nil` for non-Float32 hardware formats (Int16, Int32). The copy silently failed, producing zero samples.

### Bug 3: `calculateRMS` assumed Float32
Same `floatChannelData` guard returned 0 for non-float buffers. `hasReceivedAudio` never flipped, silence detection relied on the 30-second max timeout.

## New Pipeline Architecture

```
Hardware Mic
    │
    ▼
AVAudioEngine.inputNode
    │
    │ installTap(format: tapFormat)    ← Float32, non-interleaved, hw sample rate
    │ (AVAudioEngine converts internally from hardware format)
    │
    ▼
Tap Callback (real-time audio thread)
    ├── calculateRMS(buffer)           ← floatChannelData guaranteed non-nil
    ├── silence detection logic
    ├── copyBuffer(buffer)             ← fast Float32 path + raw fallback
    │
    └── dispatch to processingQueue ──►
                                        │
                                        ▼
                                   convertToSTT(copy)
                                        │ Fresh AVAudioConverter per buffer
                                        │ Float32/hwRate/hwChannels → Float32/16kHz/mono
                                        │
                                        ▼
                                   ThreadSafeAudioBuffer.append(samples)
```

### Key design decisions

1. **Tap format negotiation**: `installTap(format:)` receives a Float32/non-interleaved format at the hardware sample rate. AVAudioEngine normalizes the hardware format internally. This guarantees `floatChannelData` is always non-nil.

2. **Fresh converter per buffer**: `convertToSTT(_:)` creates a new `AVAudioConverter` for each buffer. This eliminates all statefulness. The overhead is negligible — converter creation is cheap compared to the actual sample rate conversion work.

3. **Two-stage conversion**: Hardware → Float32 (done by the engine's tap) → 16 kHz mono (done by `convertToSTT`). This separates concerns and makes each stage independently testable.

## Reading Diagnostics

All logging uses `os.Logger` with subsystem `com.voiceeditor.audio`, category `capture`.

### Console.app setup

1. Open Console.app
2. In the search bar, set filter: **Subsystem** is `com.voiceeditor.audio`
3. Ensure **Include Info Messages** is enabled (Action menu)

### What to look for

| Log message | Level | Meaning |
|------------|-------|---------|
| `hwFormat=... → tapFormat=...` | info | Engine started, shows negotiated formats |
| `Engine started successfully on attempt N` | info | Which retry succeeded |
| `convertToSTT: cannot create converter` | error | Format incompatibility — should never happen with Float32 tap |
| `convertToSTT: conversion error` | error | Sample rate conversion failed |
| `convertToSTT: output has 0 frames` | warning | Converter produced nothing — statefulness bug if this appears |
| `copyBuffer: floatChannelData nil` | warning | Fallback to raw copy — tap format negotiation may have failed |
| `ContinuousSession: cumulative STT samples=N` | info | Shows sample accumulation (~every 2 sec) |
| `ContinuousSession: silence detected` | info | Silence threshold crossed |
| `recordUntilSilence: total accumulated samples=N` | info | Final sample count after recording |
| `recordUntilSilence: too few samples` | warning | Fewer than 16,000 samples — check mic |
| `recordUntilSilence: RMS ... < minEnergy` | warning | Audio too quiet — ambient noise only |

### Healthy recording session

A healthy push-to-talk session produces logs like:
```
[info]  Attempt 1: hwFormat=<AVAudioFormat: 44100 Hz, Float32, non-inter, 1 ch> → tapFormat=<AVAudioFormat: 44100 Hz, Float32, non-inter, 1 ch>
[info]  Engine started successfully on attempt 1
[info]  recordUntilSilence: starting with tapFormat=...
[info]  recordUntilSilence: stopping — hasAudio=true silenceDur=1.52s totalDur=4.31s
[info]  recordUntilSilence: total accumulated samples=68960
[info]  recordUntilSilence: success — 68960 samples, RMS=0.0423
```

### Failure: no audio input
```
[warning] Attempt 1: hwFormat.sampleRate is 0 — no audio input
[warning] Attempt 2: hwFormat.sampleRate is 0 — no audio input
[warning] Attempt 3: hwFormat.sampleRate is 0 — no audio input
```
→ No microphone connected or system audio device is misconfigured.

## Files

| File | Role |
|------|------|
| `VoiceEditor/Services/AudioCaptureService.swift` | All audio capture, conversion, and silence detection |
| `VoiceEditor/Services/ThreadSafeAudioBuffer.swift` | Lock-protected `[Float]` accumulator |
| `VoiceEditor/Orchestration/ConversationCoordinator.swift` | Calls `recordUntilSilence()` and `startContinuousRecording()` — unchanged |
| `VoiceEditor/Views/DictationOverlayPanel.swift` | Reads `session.audioLevel` and `session.isSilenceDetected` — unchanged |
