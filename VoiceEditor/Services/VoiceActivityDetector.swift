import FluidAudio
import Foundation
import os

/// Lightweight wrapper around FluidAudio's `VadManager` for real-time speech detection.
///
/// Accumulates 16 kHz samples into 4096-sample chunks and runs Silero VAD on each.
/// Publishes thread-safe flags that `AudioCaptureService` reads from its tap callback.
///
/// Feeding model: each recording session owns one `AsyncStream` of sample buffers. The audio
/// processing queue pushes into it synchronously via `feed(_:session:)` (nonisolated, no Task per
/// buffer), and a single consumer task drains it in order into `process(_:session:)`. That
/// keeps chunks strictly in capture order, which Silero's recurrent state requires.
/// Public flags are `nonisolated let` because they are lock-backed and must be readable
/// from the synchronous RT tap callback.
actor VoiceActivityDetector {
    private static let log = Logger(subsystem: "com.hitokudraft.vad", category: "detector")

    /// Number of 16 kHz samples per VAD chunk (256 ms).
    private static let chunkSize = 4096

    /// `sampleBuffer` above this (2 s of audio) means the consumer is falling behind.
    private static let backlogWarningSamples = 32_000

    private let vadManager: VadManager

    /// Accumulation buffer for incoming 16 kHz samples — actor-isolated.
    private var sampleBuffer: [Float] = []

    /// Streaming state for the VAD — carries LSTM hidden/cell state across chunks.
    /// Only `process` reads/writes it, and `process` is non-reentrant by construction:
    /// it is only called by the single consumer loop, one call at a time.
    private var streamState: VadStreamState

    /// Segmentation config tuned for real-time dictation.
    private let segConfig: VadSegmentationConfig

    /// Incremented by `startSession()`. `process` drops work from any earlier session,
    /// including results that land after a new session has started.
    private var sessionID: UInt64 = 0

    /// The current session's consumer loop. An old consumer is not cancelled: once its
    /// stream is finished it drains (each stale call returns immediately) and exits.
    private var consumer: Task<Void, Never>?

    /// Producer end of the current session's sample stream, tagged with its session ID.
    /// Lock-backed so `feed` / `endSession` can be called synchronously from any thread.
    ///
    /// Buffering is `.unbounded` on purpose: Silero's state assumes contiguous audio, so
    /// dropping buffers would corrupt speechEnd timing. Worst case cost is 64 KB/s of backlog.
    nonisolated private let inlet = OSAllocatedUnfairLock<(session: UInt64, continuation: AsyncStream<[Float]>.Continuation)?>(initialState: nil)

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

    deinit {
        // The consumer holds `self` weakly and would otherwise wait on an open stream forever.
        endSession()
    }

    /// Creates a fully initialized detector. Downloads Silero VAD model on first use (~2 MB).
    static func create() async throws -> VoiceActivityDetector {
        let manager = try await VadManager()
        let state = await manager.makeStreamState()
        return VoiceActivityDetector(vadManager: manager, streamState: state)
    }

    // MARK: - Session Lifecycle

    /// Ends any previous session, resets all state, and opens a new sample stream.
    /// - Returns: the new session ID, for `endSession(_:)`.
    @discardableResult
    func startSession() async -> UInt64 {
        endSession()
        sessionID &+= 1
        let id = sessionID

        sampleBuffer.removeAll(keepingCapacity: true)
        speechDetected.reset()
        silenceAfterSpeech.reset()
        speechProbability.set(0)

        streamState = await vadManager.makeStreamState()

        // Install the inlet only after the await above, and only if no newer session
        // started meanwhile, so `feed` never reaches a half-initialized session.
        guard id == sessionID else { return id }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        inlet.withLock { $0 = (id, continuation) }
        consumer = Task { [weak self] in
            for await samples in stream {
                guard let self else { return }
                await self.process(samples, session: id)
            }
        }
        return id
    }

    /// Queues 16 kHz samples for `session`. Synchronous and non-blocking; a no-op when no
    /// session is open or when `session` is not the open one (a late block from an old
    /// recording's processing queue must not leak into a newer recording's stream).
    nonisolated func feed(_ samples: [Float], session: UInt64) {
        inlet.withLock { current in
            guard let open = current, open.session == session else { return }
            _ = open.continuation.yield(samples)
        }
    }

    /// Finishes the sample stream. Already-queued samples are still processed.
    /// - Parameter session: when given, only ends the stream if it still belongs to that
    ///   session, so a late teardown cannot close a newer session's stream.
    nonisolated func endSession(_ session: UInt64? = nil) {
        inlet.withLock { current in
            guard let open = current else { return }
            if let session, session != open.session { return }
            open.continuation.finish()
            current = nil
        }
    }

    // MARK: - Sample Processing

    /// Accumulates 16 kHz samples and runs VAD when a full chunk (4096 samples) is ready.
    /// Non-reentrant by construction: only the single consumer loop calls this, and it
    /// awaits each call before the next. Session checks guard against `startSession()`
    /// interleaving at the `await`.
    private func process(_ samples: [Float], session id: UInt64) async {
        guard id == sessionID else { return }
        sampleBuffer.append(contentsOf: samples)
        if sampleBuffer.count > Self.backlogWarningSamples {
            Self.log.warning("VAD: sample backlog \(self.sampleBuffer.count) samples")
        }

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
                // A new session started while we were suspended: its state is not ours to touch.
                guard id == sessionID else { return }

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
