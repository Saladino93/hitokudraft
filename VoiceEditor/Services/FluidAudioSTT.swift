import FluidAudio
import Foundation

final class FluidAudioSTT: STTService, @unchecked Sendable {
    private let manager: AsrManager

    /// Minimum samples (1 second at 16 kHz) — belt-and-suspenders guard.
    private static let minSamples = 16_000

    /// Below this confidence, the transcription is likely a hallucination.
    /// Kept low (0.1) to support multilingual input — Parakeet v3 may report
    /// lower confidence for non-English European languages.
    private static let minConfidence: Float = 0.2

    init(models: AsrModels) async throws {
        self.manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard samples.count >= Self.minSamples else {
            throw AudioCaptureService.AudioCaptureError.emptyRecording
        }
        let result = try await manager.transcribe(samples, source: .microphone)

        guard result.confidence >= Self.minConfidence else {
            throw STTError.lowConfidence
        }

        return result.text
    }

    enum STTError: LocalizedError {
        case lowConfidence

        var errorDescription: String? {
            switch self {
            case .lowConfidence:
                return L("error.low_confidence")
            }
        }
    }
}
