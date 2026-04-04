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

enum STTModelRegistry {
    static let availableModels: [STTModelOption] = [
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

    static var defaultModel: STTModelOption { availableModels[0] }
}
