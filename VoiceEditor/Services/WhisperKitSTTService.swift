import Foundation
import WhisperKit
import os

final class WhisperKitSTTService: STTService, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.hitokudraft.stt", category: "whisperkit")
    private let pipe: WhisperKit

    /// Downloads (if needed) and loads the named Whisper model.
    /// `modelName`: WhisperKit model identifier, e.g. `"base.en"`, `"tiny.en"`.
    init(modelName: String) async throws {
        let config = WhisperKitConfig(model: modelName, verbose: false)
        self.pipe = try await WhisperKit(config)
        Self.log.info("WhisperKitSTTService loaded: model=\(modelName, privacy: .public)")
    }

    // MARK: - STTService

    func transcribe(samples: [Float]) async throws -> String {
        let duration = Double(samples.count) / 16_000.0
        Self.log.info("transcribe: samples=\(samples.count) duration=\(duration, format: .fixed(precision: 2))s")

        let opts = DecodingOptions(task: .transcribe, language: "en")
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
        let text = (results.first?.text ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !text.isEmpty else {
            Self.log.warning("transcribe: empty result")
            throw WhisperKitSTTError.emptyTranscription
        }

        Self.log.info("transcribe: success text_len=\(text.count)")
        return text
    }

    /// Batch mode — `TranscriptionPipeline` falls back to Path A (200 ms polling).
    func makeStreamingSession() -> (any StreamingSession)? { nil }

    // MARK: - Errors

    enum WhisperKitSTTError: LocalizedError {
        case emptyTranscription

        var errorDescription: String? {
            L("error.mlx_empty")
        }
    }
}
