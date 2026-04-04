import FluidAudio
import Foundation
import os

/// Lightweight wrapper around FluidAudio's `VadManager` for real-time speech detection.
///
/// Accumulates 16 kHz samples into 4096-sample chunks and runs Silero VAD on each.
/// Publishes thread-safe flags that `AudioCaptureService` reads from its tap callback.
/// Actor-isolated VAD: all mutable state (`sampleBuffer`, `streamState`) is serialized
/// automatically. Public flags are `nonisolated let` because they are already thread-safe
/// via NSLock internally and must be readable from the synchronous RT tap callback.
actor VoiceActivityDetector {
    private static let log = Logger(subsystem: "com.hitokudraft.vad", category: "detector")

    /// Number of 16 kHz samples per VAD chunk (256 ms).
    private static let chunkSize = 4096

    private let vadManager: VadManager

    /// Accumulation buffer for incoming 16 kHz samples — actor-isolated.
    private var sampleBuffer: [Float] = []

    /// Streaming state for the VAD — carries LSTM hidden/cell state across chunks.
    /// Actor isolation ensures only one `feedSamples` call reads/writes this at a time.
    private var streamState: VadStreamState

    /// Segmentation config tuned for real-time dictation.
    private let segConfig: VadSegmentationConfig

    // MARK: - Public Flags (nonisolated — safe to read from synchronous tap callback)

    /// Set when a `speechStart` event fires.
    nonisolated let speechDetected = LockedFlag()

    /// Set when a `speechEnd` event fires (speech was detected, then silence followed).
    nonisolated let silenceAfterSpeech = LockedFlag()

    /// Current speech probability (0.0–1.0) — for optional UI use.
    nonisolated let speechProbability = LockedFloat()

    // MARK: - Init

    init(vadManager: VadManager, streamState: VadStreamState) {
        self.vadManager = vadManager
        self.streamState = streamState

        var config = VadSegmentationConfig()
        config.minSpeechDuration = 0.3      // 300ms — filter coughs/clicks
        config.minSilenceDuration = 0.5     // 500ms — triggers speechEnd event
        config.speechPadding = 0.1          // 100ms context padding
        self.segConfig = config
    }

    /// Creates a fully initialized detector. Downloads Silero VAD model on first use (~2 MB).
    static func create() async throws -> VoiceActivityDetector {
        let manager = try await VadManager()
        let state = await manager.makeStreamState()
        return VoiceActivityDetector(vadManager: manager, streamState: state)
    }

    // MARK: - Session Lifecycle

    /// Resets all state for a new recording session.
    func reset() async {
        sampleBuffer.removeAll(keepingCapacity: true)

        speechDetected.reset()
        silenceAfterSpeech.reset()
        speechProbability.set(0)

        streamState = await vadManager.makeStreamState()
    }

    // MARK: - Sample Processing

    /// Accumulates 16 kHz samples and runs VAD when a full chunk (4096 samples) is ready.
    /// Actor isolation serializes concurrent calls — no explicit locking needed.
    func feedSamples(_ samples: [Float]) async {
        sampleBuffer.append(contentsOf: samples)

        // Process all complete chunks
        while true {
            guard sampleBuffer.count >= Self.chunkSize else { return }
            let chunk = Array(sampleBuffer.prefix(Self.chunkSize))
            sampleBuffer.removeFirst(Self.chunkSize)

            do {
                let result = try await vadManager.processStreamingChunk(
                    chunk,
                    state: streamState,
                    config: segConfig,
                    returnSeconds: false
                )

                streamState = result.state
                speechProbability.set(result.probability)

                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        Self.log.info("VAD: speechStart at sample \(event.sampleIndex)")
                        speechDetected.set()
                        silenceAfterSpeech.reset()
                    case .speechEnd:
                        Self.log.info("VAD: speechEnd at sample \(event.sampleIndex)")
                        silenceAfterSpeech.set()
                    }
                }
            } catch {
                Self.log.error("VAD processStreamingChunk failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
