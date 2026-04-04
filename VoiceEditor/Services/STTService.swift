import Foundation

/// Backend-agnostic transcription event emitted by any StreamingSession.
enum STTEvent: Sendable {
    case displayUpdate(confirmedText: String, provisionalText: String)
    case ended(fullText: String)
}

/// Minimal interface over a live streaming inference session.
/// Callers do not need to import any backend-specific framework.
protocol StreamingSession: AnyObject {
    var events: AsyncStream<STTEvent> { get }
    func feedAudio(samples: [Float])
    func stop()
}

protocol STTService: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func makeStreamingSession() -> (any StreamingSession)?
}

extension STTService {
    func makeStreamingSession() -> (any StreamingSession)? { nil }
}
