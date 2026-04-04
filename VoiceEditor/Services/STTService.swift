import Foundation
import MLXAudioSTT

/// Minimal interface over `StreamingInferenceSession` so callers don't need to
/// import MLXAudioSTT or cast to a concrete type.
protocol StreamingSession: AnyObject {
    var events: AsyncStream<TranscriptionEvent> { get }
    func feedAudio(samples: [Float])
    func stop()
}

/// Conformance — `StreamingInferenceSession` satisfies all three requirements
/// above with its public API. No `@retroactive` needed since `StreamingSession`
/// is defined in this module.
extension StreamingInferenceSession: StreamingSession {}

protocol STTService: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func makeStreamingSession() -> (any StreamingSession)?
}

extension STTService {
    func makeStreamingSession() -> (any StreamingSession)? { nil }
}
