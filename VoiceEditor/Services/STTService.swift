import Foundation

protocol STTService: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}
