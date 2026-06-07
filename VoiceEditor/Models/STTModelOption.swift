import Foundation

enum STTBackend: String, Hashable, Sendable {
    case fluidAudio      // CoreML Parakeet TDT (ANE)
    case mlxAudio        // Transformer models via mlx-audio-swift (Metal GPU)
    case whisperKit      // Whisper models via WhisperKit (CoreML/ANE)
}

struct STTModelOption: Identifiable, Hashable {
    let name: String
    let path: String          // HuggingFace repo ID (mlxAudio) or empty (fluidAudio)
    let backend: STTBackend
    let description: String
    let estimatedMemoryGB: Double
    let supportsNativeStreaming: Bool
    /// nil = multilingual, non-nil = restricted (e.g. "English only")
    let languageRestriction: String?

    var id: String { path.isEmpty ? name : path }
}

extension STTModelOption {
    /// True when this is the "None" sentinel (no STT loaded — use LLM audio).
    var isNone: Bool { path == "__none_stt__" }
}

enum STTModelRegistry {
    /// Sentinel: no STT loaded. Only works with audio-capable LLMs (Gemma 4).
    /// Dictation loads Parakeet on-demand when needed.
    static let noSTT = STTModelOption(
        name: "None",
        path: "__none_stt__",
        backend: .fluidAudio,
        description: "No dedicated speech model. Voice commands use an audio-capable LLM (Gemma 4); dictation loads a speech model on demand.",
        estimatedMemoryGB: 0,
        supportsNativeStreaming: false,
        languageRestriction: nil
    )

    static let availableModels: [STTModelOption] = [
        noSTT,
        STTModelOption(
            name: "Whisper Tiny",
            path: "tiny.en",
            backend: .whisperKit,
            description: "Fastest, lower accuracy (English only)",
            estimatedMemoryGB: 0.09,
            supportsNativeStreaming: false,
            languageRestriction: "English only"
        ),
        STTModelOption(
            name: "Whisper Base",
            path: "base.en",
            backend: .whisperKit,
            description: "Fast, lower accuracy (English only)",
            estimatedMemoryGB: 0.18,
            supportsNativeStreaming: false,
            languageRestriction: "English only"
        ),
        STTModelOption(
            name: "Parakeet TDT v3",
            path: "",
            backend: .fluidAudio,
            description: "Fast CoreML speech recognition (European languages)",
            estimatedMemoryGB: 0.6,
            supportsNativeStreaming: false,
            languageRestriction: nil
        ),
        STTModelOption(
            name: "Qwen3-ASR 0.6B (6-bit)",
            path: "mlx-community/Qwen3-ASR-0.6B-6bit",
            backend: .mlxAudio,
            description: "Lightweight streaming ASR (multilingual)",
            estimatedMemoryGB: 0.8,
            supportsNativeStreaming: true,
            languageRestriction: nil
        ),
        STTModelOption(
            name: "Qwen3-ASR 1.7B",
            path: "mlx-community/Qwen3-ASR-1.7B-bf16",
            backend: .mlxAudio,
            description: "High-quality streaming ASR (multilingual)",
            estimatedMemoryGB: 3.4,
            supportsNativeStreaming: true,
            languageRestriction: nil
        ),
    ]

    /// RAM-based default, matching the same thresholds as LLM smartDefault.
    /// ≥16 GB → Parakeet TDT v3 (best quality, multilingual, 0.6 GB, ANE)
    /// ≥8 GB  → Whisper Base (180 MB, English only)
    /// <8 GB  → Whisper Tiny (90 MB, English only)
    static var defaultModel: STTModelOption {
        let ramGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        if ramGB >= 16 {
            return availableModels.first { $0.backend == .fluidAudio } ?? availableModels[0]
        } else if ramGB >= 8 {
            return availableModels.first { $0.path == "base.en" } ?? availableModels[0]
        } else {
            return availableModels.first { $0.path == "tiny.en" } ?? availableModels[0]
        }
    }
}
