# HitokuInference

A Swift package that provides a unified interface for routing inference requests across multiple on-device backends. Built for [Hitoku Draft](https://hitoku.me/draft/), but designed as a standalone, reusable abstraction.

## Why this exists

Google's LiteRT (formerly TensorFlow Lite) provides a C API for on-device inference with Gemma 4 models, but as of April 2026 there are no official Swift bindings or Swift Package Manager support. To use LiteRT from a native macOS app, you need to write your own C-to-Swift wrapper, handle `dlopen` loading of the dylibs, and manage the conversation lifecycle manually.

This package does that wrapping — and while we were at it, we made the abstraction generic enough to support multiple backends behind one protocol. The result is that adding LiteRT (or any future framework) to a Swift app requires zero changes to the calling code.

## Motivation

Running LLMs locally on Apple Silicon means choosing between frameworks — MLX for GPU-accelerated transformer inference, LiteRT for Google's optimized multimodal models, potentially CoreML in the future. Each has different APIs, capabilities, and supported input types.

HitokuInference solves this by defining a single `InferenceBackend` protocol. The app's orchestration layer talks to the protocol, never to a specific framework. Switching backends, adding new ones, or running multiple simultaneously requires zero changes to the calling code.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                InferenceRouter                   │
│  Routes requests to the best available backend   │
│  based on input modalities and preferences       │
├────────────────┬────────────────┬────────────────┤
│   MLXBackend   │  LiteRTBackend │   (future)     │
│   text + image │  text + audio  │   CoreML, etc. │
│                │    + image     │                │
└────────────────┴────────────────┴────────────────┘
```

### Core Protocol

```swift
public protocol InferenceBackend: Sendable {
    var supportedModalities: Set<InputModality> { get }
    var isLoaded: Bool { get }
    func loadModel(at path: String, config: BackendConfig) async throws
    func unload()
    func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error>
}
```

### Products

| Library | Dependencies | Purpose |
|---------|-------------|---------|
| `HitokuInference` | None | Core protocol, `InferenceRequest`, `InferenceRouter`, `InputModality` |
| `MLXBackend` | mlx-swift, mlx-swift-lm | Wraps MLXLLM/MLXVLM for text and vision models on Metal GPU |
| `LiteRTBackend` | CLiteRTEngine (C header) | Wraps LiteRT-LM C API for Gemma 4 multimodal models via `dlopen` |

### InferenceRouter

The router itself conforms to `InferenceBackend`, so callers can treat it as a single backend:

```swift
let router = InferenceRouter()
router.register(mlxBackend, as: "mlx")
router.register(liteRTBackend, as: "litert")

// Automatically picks the right backend based on what the request contains
let stream = router.generate(request: InferenceRequest(
    text: "Summarize this",
    images: [screenshot],
    maxTokens: 500
))
```

**Resolution order:**
1. Preferred backend (if set, loaded, and supports the request's modalities)
2. Best-fit loaded backend that covers all needed input types
3. Any loaded backend as fallback (caller handles pre-processing like STT)

### InferenceRequest

A single value type that can carry any combination of inputs:

```swift
public struct InferenceRequest: Sendable {
    var systemPrompt: String?
    var text: String?
    var audio: Data?          // Raw PCM or WAV
    var images: [CGImage]?
    var maxTokens: Int
    var temperature: Float
    var topP: Float?
    var repetitionPenalty: Float?
    // ...
}
```

Backends inspect only the fields they support. A text-only backend ignores `audio` and `images`. A multimodal backend like LiteRT uses all three.

## LiteRT Setup

The LiteRT backend loads Google's dylibs at runtime via `dlopen`. These are not included in the repository. To enable Gemma 4 support:

```bash
./setup_litert_libs.sh
```

This downloads the required dylibs into `Libraries/macos_arm64/`. The app runs fine without them — LiteRT models simply won't appear in the model picker.

## Adding a New Backend

1. Create a new target that depends on `HitokuInference`
2. Implement `InferenceBackend` with your framework
3. Register it with the router: `router.register(myBackend, as: "myframework")`

The router handles everything else — modality matching, fallback resolution, and streaming.
