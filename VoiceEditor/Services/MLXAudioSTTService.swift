import Foundation
import HuggingFace
import MLX
import MLXAudioSTT
import os

// MARK: - MLX streaming adapter

/// Wraps `StreamingInferenceSession` and converts `TranscriptionEvent` → `STTEvent`
/// so callers only depend on the backend-agnostic `StreamingSession` protocol.
private final class MLXStreamingSession: StreamingSession {
    private let inner: StreamingInferenceSession
    let events: AsyncStream<STTEvent>

    init(_ inner: StreamingInferenceSession) {
        self.inner = inner
        let (stream, cont) = AsyncStream<STTEvent>.makeStream()
        self.events = stream

        Task.detached { [cont] in
            for await event in inner.events {
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    cont.yield(.displayUpdate(confirmedText: confirmed, provisionalText: provisional))
                case .ended(let full):
                    cont.yield(.ended(fullText: full))
                    cont.finish()
                    return
                default:
                    break
                }
            }
            cont.finish()
        }
    }

    func feedAudio(samples: [Float]) { inner.feedAudio(samples: samples) }
    func stop() { inner.stop() }
}

// MARK: -

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

    /// STTService protocol conformance — wraps the MLX session in an adapter
    /// that converts `TranscriptionEvent` → `STTEvent`.
    func makeStreamingSession() -> (any StreamingSession)? {
        guard let session = createStreamingSession() else { return nil }
        return MLXStreamingSession(session)
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
