import Foundation

enum STTBackend: String, Hashable, Sendable {
    case fluidAudio      // CoreML models via FluidAudio (ANE)
    case whisperKit      // Whisper models via WhisperKit (CoreML/ANE)
}

struct STTModelOption: Identifiable, Hashable {
    let name: String
    let path: String          // HuggingFace repo ID or empty (fluidAudio default)
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
        description: "No STT loaded (requires audio-capable LLM like Gemma 4)",
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
            name: "Qwen3-ASR 0.6B",
            path: "qwen3-asr",
            backend: .fluidAudio,
            description: "Multilingual streaming ASR (30+ languages)",
            estimatedMemoryGB: 0.7,
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
