import FluidAudio
import Foundation
import os

/// Lightweight wrapper around FluidAudio's `VadManager` for real-time speech detection.
///
/// Accumulates 16 kHz samples into 4096-sample chunks and runs Silero VAD on each.
/// Publishes thread-safe flags that `AudioCaptureService` reads from its tap callback.
final class VoiceActivityDetector: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.hitokudraft.vad", category: "detector")

    /// Number of 16 kHz samples per VAD chunk (256 ms).
    private static let chunkSize = 4096

    private let vadManager: VadManager

    /// Accumulation buffer for incoming 16 kHz samples (guarded by lock).
    private let lock = NSLock()
    private var sampleBuffer: [Float] = []

    /// Streaming state for the VAD — carries LSTM hidden/cell state across chunks.
    private var streamState: VadStreamState

    /// Segmentation config tuned for real-time dictation.
    private let segConfig: VadSegmentationConfig

    // MARK: - Public Flags

    /// Set when a `speechStart` event fires.
    let speechDetected = LockedFlag()

    /// Set when a `speechEnd` event fires (speech was detected, then silence followed).
    let silenceAfterSpeech = LockedFlag()

    /// Current speech probability (0.0–1.0) — for optional UI use.
    let speechProbability = LockedFloat()

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
        lock.lock()
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        speechDetected.reset()
        silenceAfterSpeech.reset()
        speechProbability.set(0)

        streamState = await vadManager.makeStreamState()
    }

    // MARK: - Sample Processing

    /// Accumulates 16 kHz samples and runs VAD when a full chunk (4096 samples) is ready.
    /// Called from the processing queue in `AudioCaptureService`.
    func feedSamples(_ samples: [Float]) async {
        // Append samples under lock
        lock.lock()
        sampleBuffer.append(contentsOf: samples)
        lock.unlock()

        // Process all complete chunks
        while true {
            lock.lock()
            guard sampleBuffer.count >= Self.chunkSize else {
                lock.unlock()
                return
            }
            let chunk = Array(sampleBuffer.prefix(Self.chunkSize))
            sampleBuffer.removeFirst(Self.chunkSize)
            lock.unlock()

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
