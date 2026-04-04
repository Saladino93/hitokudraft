import Foundation
import HuggingFace
import MLX
import MLXAudioSTT
import os

final class MLXAudioSTTService: STTService, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.hitokudraft.stt", category: "mlx-audio")

    private let model: Qwen3ASRModel

    /// Downloads (if needed) and loads the MLX STT model identified by its
    /// HuggingFace repo path.
    init(modelPath: String, cacheDirectory: URL? = nil) async throws {
        let cache: HubCache = if let cacheDirectory {
            HubCache(cacheDirectory: cacheDirectory)
        } else {
            .default
        }
        self.model = try await Qwen3ASRModel.fromPretrained(modelPath, cache: cache)
    }

    // MARK: - STTService

    func transcribe(samples: [Float]) async throws -> String {
        let duration = Double(samples.count) / 16_000.0
        let audio = MLXArray(samples)
        Self.log.info("transcribe: model=qwen3 samples=\(samples.count) duration=\(duration)s")

        let params = STTGenerateParameters(language: "auto")
        let output = model.generate(audio: audio, generationParameters: params)

        Self.log.info("transcribe: tokens=\(output.generationTokens) tps=\(output.generationTps) time=\(output.totalTime)s peak=\(output.peakMemoryUsage)GB")

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Self.log.warning("transcribe: empty text (tokens=\(output.generationTokens) totalTokens=\(output.totalTokens))")
            throw MLXSTTError.emptyTranscription
        }

        Self.log.info("transcribe: success text_len=\(text.count)")
        return text
    }

    // MARK: - Native Streaming (Qwen3-ASR only)

    /// STTService protocol conformance — returns the streaming session as `any StreamingSession`.
    func makeStreamingSession() -> (any StreamingSession)? {
        createStreamingSession()
    }

    /// Creates a `StreamingInferenceSession` for live, incremental transcription.
    func createStreamingSession() -> StreamingInferenceSession? {
        var config = StreamingConfig()
        config.decodeIntervalSeconds = 0.5
        config.boundaryDecodeIntervalSeconds = 0.2
        config.delayPreset = .realtime          // ~200ms token promotion
        config.language = "auto"
        config.temperature = 0.0
        config.finalizeCompletedWindows = true
        return StreamingInferenceSession(model: model, config: config)
    }

    // MARK: - Errors

    enum MLXSTTError: LocalizedError {
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .emptyTranscription:
                return L("error.mlx_empty")
            }
        }
    }
}
