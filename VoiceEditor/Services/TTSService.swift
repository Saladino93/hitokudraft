import Foundation
import AVFoundation
import CoreML
import FluidAudio
import os

// MARK: - TTSProvider Protocol

/// Abstract TTS synthesis backend.
///
/// Conformers are genuinely `Sendable`: the underlying FluidAudio engine (e.g. the
/// non-Sendable `KokoroTtsManager` class) lives inside a `SynthesisWorker`, which owns it
/// on a single task and serializes every call to it. No `@unchecked Sendable` is needed.
///
/// To add a new backend: conform to this protocol, add a case to `TtsBackend`,
/// and add a branch in `TTSService.defaultProvider`. No other changes needed.
protocol TTSProvider: AnyObject, Sendable {
    /// One-time download + model initialization. May be called multiple times safely
    /// (callers guard on `isAvailable`).
    func initialize() async throws
    /// Synthesize `text` → WAV audio `Data` at 24 kHz.
    /// `speed` is 0.5–2.0; backends that do not support speed silently ignore it.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
    /// `true` once `initialize()` has completed successfully.
    var isAvailable: Bool { get }
    /// All female voice identifiers available for this backend.
    static var femaleVoices: [String] { get }
    /// Recommended default female voice.
    static var defaultVoice: String { get }
}

// MARK: - Synthesis Worker

/// Errors raised by `SynthesisWorker` itself (engine errors pass through unchanged).
enum SynthesisWorkerError: LocalizedError {
    /// The worker's job stream was finished (provider deallocated) before the job was queued.
    case workerStopped

    var errorDescription: String? {
        switch self {
        case .workerStopped: return "TTS synthesis worker has stopped"
        }
    }
}

/// FIFO front for a non-Sendable synthesis engine. The engine is created inside the worker
/// task and never escapes it, so neither the engine nor this class needs @unchecked Sendable.
///
/// Jobs run strictly one at a time in submission order, which also removes any reentrancy
/// into the engine (two overlapping `synthesize` calls on one FluidAudio manager).
final class SynthesisWorker<Engine>: Sendable {

    private struct Job: Sendable {
        enum Kind: Sendable {
            case initialize(CheckedContinuation<Void, any Error>)
            case synthesize(text: String, voice: String, speed: Float, CheckedContinuation<Data, any Error>)
        }
        let kind: Kind
        /// Set by the caller's cancellation handler; a synthesis job that has not started yet is skipped.
        let cancelled = LockedFlag()
    }

    private let inlet: AsyncStream<Job>.Continuation

    /// Set once `initialize` has succeeded. Lock-backed → race-free read from any isolation.
    let ready = LockedFlag()

    init(
        makeEngine: @escaping @Sendable () -> Engine,
        initialize: @escaping @Sendable (Engine) async throws -> Void,
        synthesize: @escaping @Sendable (Engine, _ text: String, _ voice: String, _ speed: Float) async throws -> Data
    ) {
        let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        inlet = continuation
        // Must not capture `self`: `deinit` finishes the stream, which is what ends this loop.
        // Every job is resumed exactly once.
        Task.detached(priority: .userInitiated) { [ready] in
            let engine = makeEngine()
            for await job in stream {
                switch job.kind {
                case .initialize(let c):
                    if ready.value { c.resume(); continue }
                    do {
                        try await initialize(engine)
                        ready.set()
                        c.resume()
                    } catch {
                        c.resume(throwing: error)
                    }
                case .synthesize(let text, let voice, let speed, let c):
                    if job.cancelled.value { c.resume(throwing: CancellationError()); continue }
                    do {
                        c.resume(returning: try await synthesize(engine, text, voice, speed))
                    } catch {
                        c.resume(throwing: error)
                    }
                }
            }
            // Stream finished and drained: `engine` is released here.
        }
    }

    deinit {
        // Buffered jobs still drain; the engine is freed when the loop ends.
        inlet.finish()
    }

    /// Runs (or joins) engine initialization. No-op once `ready` is set.
    func initialize() async throws {
        try await submit { .initialize($0) }
    }

    /// Queues a synthesis job. If the calling task is cancelled before the job starts,
    /// the job is skipped and this throws `CancellationError`.
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await submit { .synthesize(text: text, voice: voice, speed: speed, $0) }
    }

    private func submit<T: Sendable>(
        _ makeKind: (CheckedContinuation<T, any Error>) -> Job.Kind
    ) async throws -> T {
        let holder = OSAllocatedUnfairLock<Job?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
                let job = Job(kind: makeKind(c))
                holder.withLock { $0 = job }
                // Publish to `holder` first, then check: a cancel that fired before the
                // publish is caught here, one after it is caught by `onCancel`.
                if Task.isCancelled { job.cancelled.set() }
                if case .terminated = inlet.yield(job) {
                    c.resume(throwing: SynthesisWorkerError.workerStopped)
                }
            }
        } onCancel: {
            holder.withLock { $0?.cancelled.set() }
        }
    }
}

// MARK: - Kokoro Backend

/// Phoneme-based, multi-voice synthesis via Kokoro 82M CoreML.
/// American English voices are production-tested; other languages are experimental.
/// Synthesizes all frames at once — low latency for short to medium text.
final class KokoroTTSProvider: TTSProvider {

    private static let log = Logger(subsystem: "com.hitokudraft.app", category: "KokoroTTSProvider")

    private let worker: SynthesisWorker<KokoroTtsManager>

    init(cacheDirectory: URL? = nil) {
        worker = SynthesisWorker(
            makeEngine: { KokoroTtsManager(directory: cacheDirectory) },
            initialize: { try await KokoroTTSProvider.initialize(manager: $0, cacheDirectory: cacheDirectory) },
            synthesize: { try await $0.synthesize(text: $1, voice: $2, voiceSpeed: $3) }
        )
    }

    func initialize() async throws {
        try await worker.initialize()
    }

    /// Runs on the worker task, which owns `manager`.
    private static func initialize(manager: KokoroTtsManager, cacheDirectory: URL?) async throws {
        let units = LaunchSafety.ttsComputeUnits
        Self.log.info("Kokoro compute units: \(LaunchSafety.describe(units), privacy: .public)")

        guard LaunchSafety.preferSafeComputeUnits else {
            // Default FluidAudio path: `.cpuAndGPU` plus a warm-up prediction per variant.
            try await manager.initialize()
            return
        }

        // Safe path: FluidAudio's `TtsModels.download` hardcodes `.cpuAndGPU`, whose MPSGraph
        // compile can abort the process (see `LaunchSafety`). Load both variants ourselves with
        // safe compute units and hand them to the manager. Both variants must be supplied —
        // a missing one is lazily re-loaded by FluidAudio with `.cpuAndGPU`.
        // Trade-off: no warm-up prediction, so the first synthesis is slightly slower.
        // Directory mirrors `TtsModels.download`: `<cacheRoot>/Models`, models in `Models/kokoro/`,
        // so existing downloads are reused (`loadModels` downloads only if files are missing).
        let root = try cacheDirectory ?? TtsModels.cacheDirectoryURL()
        let modelsDirectory = root.appendingPathComponent(TtsConstants.defaultModelsSubdirectory)
        let variants = ModelNames.TTS.Variant.allCases
        let loaded = try await DownloadUtils.loadModels(
            .kokoro,
            modelNames: variants.map(\.fileName),
            directory: modelsDirectory,
            computeUnits: units
        )
        var models: [ModelNames.TTS.Variant: MLModel] = [:]
        for variant in variants {
            guard let model = loaded[variant.fileName] else {
                throw TTSError.modelNotFound(variant.fileName)
            }
            models[variant] = model
        }
        try await manager.initialize(models: TtsModels(models: models))
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await worker.synthesize(text: text, voice: voice, speed: speed)
    }

    var isAvailable: Bool { worker.ready.value }

    /// All voices whose second character is 'f' (female prefix convention).
    /// e.g. "af_heart" (American), "bf_alice" (British), "if_sara" (Italian).
    static var femaleVoices: [String] {
        TtsConstants.availableVoices.filter { voice in
            let chars = Array(voice)
            return chars.count >= 2 && chars[1] == "f"
        }
    }

    static var defaultVoice: String { TtsConstants.recommendedVoice }
}

// MARK: - PocketTTS Backend

/// Flow-matching autoregressive synthesis via PocketTTS CoreML.
/// Autoregressive (80 ms/frame) — suited for longer passages.
/// Speed parameter is not supported by this backend and is silently ignored.
final class PocketTTSProvider: TTSProvider {

    private let worker: SynthesisWorker<PocketTtsManager>

    init(cacheDirectory: URL? = nil) {
        // Note: PocketTTS is still `.cpuAndGPU`-only at the pinned FluidAudio revision —
        // `PocketTtsModelStore` hardcodes its compute units and exposes no override, so
        // `LaunchSafety.ttsComputeUnits` cannot be applied here.
        worker = SynthesisWorker(
            makeEngine: { PocketTtsManager(directory: cacheDirectory) },
            initialize: { try await $0.initialize() },
            // PocketTTS has no speed parameter — `speed` is intentionally ignored.
            synthesize: { manager, text, voice, _ in try await manager.synthesize(text: text, voice: voice) }
        )
    }

    func initialize() async throws {
        try await worker.initialize()
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await worker.synthesize(text: text, voice: voice, speed: speed)
    }

    var isAvailable: Bool { worker.ready.value }

    /// Female voices compatible with the current PocketTTS model (125-frame prompt).
    /// Several voices in the HuggingFace repo use variable-length prompts that are
    /// incompatible with the hardcoded voicePromptLength=125 in FluidAudio — excluded.
    static var femaleVoices: [String] {
        ["azelma", "cosette", "eponine", "fantine", "mary"]
    }
    static var defaultVoice: String { "fantine" }
}

// MARK: - TTSService

/// Manages TTS backend lifecycle and audio playback.
///
/// Usage:
/// ```swift
/// // Fire-and-forget (non-editable display mode):
/// Task { await TTSService.shared.speak(text: result, voice: voice, speed: speed, backend: .kokoro) }
///
/// // Stop on new voice activation:
/// await TTSService.shared.stop()
/// ```
///
/// The active provider is initialized lazily on the first `speak()` call.
/// All synthesis runs off the main thread. Errors are swallowed — TTS is always non-critical.
actor TTSService {

    private static let log = Logger(subsystem: "com.hitokudraft.app", category: "TTSService")

    /// Builds a provider for a backend, rooted at the given cache directory.
    typealias ProviderFactory = @Sendable (TtsBackend, URL) -> any TTSProvider

    /// Production provider factory.
    static let defaultProvider: ProviderFactory = { backend, cacheDirectory in
        switch backend {
        case .kokoro:    KokoroTTSProvider(cacheDirectory: cacheDirectory)
        case .pocketTts: PocketTTSProvider(cacheDirectory: cacheDirectory)
        }
    }

    static let shared = TTSService()

    private let providerFactory: ProviderFactory

    /// - Parameter providerFactory: injectable for tests; production uses `defaultProvider`.
    init(providerFactory: @escaping ProviderFactory = TTSService.defaultProvider) {
        self.providerFactory = providerFactory
    }

    private var provider: (any TTSProvider)?
    private var currentBackend: TtsBackend?
    /// Shared initialization task — concurrent callers await the same task
    /// instead of skipping (which caused "model not initialized" errors).
    private var initTask: Task<Void, any Error>?
    /// Retained to keep playback alive. Replaced on each new utterance.
    private var player: AVAudioPlayer?
    /// Fires on @MainActor when a new segment starts playing. Set by the coordinator
    /// to drive overlay text highlighting. Receives "" when playback ends or is stopped.
    private var onSegmentStart: (@Sendable @MainActor (String) -> Void)?

    /// Playback generation. Bumped by `stop()`. Every drain loop and every `speak` captures
    /// it on entry and checks `isLive(_:)` after every `await` before touching `player`,
    /// the queue, or the highlight callback, so a loop that was stopped while suspended
    /// can never start playing a stale segment.
    private var generation: UInt64 = 0

    // MARK: - Sentence Queue (streaming TTS)
    /// Sentences waiting to be synthesized and played, in arrival order.
    private var queuedSentences: [String] = []
    /// Background task draining `queuedSentences`; nil when the queue is idle.
    private var queueTask: Task<Void, Never>?

    /// Unified cache root — same directory used by LLM and ASR model downloads.
    /// TTS models land in `<cacheRoot>/Models/kokoro/` and `<cacheRoot>/Models/pocket-tts/`.
    private var cacheRoot: URL { ModelManager.modelsCacheRoot }

    // MARK: - Configuration

    /// Switch to `backend` if it differs from the current one.
    /// Idempotent: repeated calls with the same backend are no-ops.
    func configure(backend: TtsBackend) {
        guard backend != currentBackend else { return }
        currentBackend = backend
        initTask?.cancel()
        initTask = nil
        provider = providerFactory(backend, cacheRoot)
    }

    /// Pre-initializes the TTS provider so it's ready when the first sentence arrives.
    /// Call concurrently with LLM generation to hide cold-start latency.
    func preWarm(backend: TtsBackend) async {
        configure(backend: backend)
        guard let provider, !provider.isAvailable else { return }
        do {
            try await ensureInitialized(provider: provider)
        } catch {
            Self.log.error("TTS pre-warm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers a callback that fires when each TTS segment begins playback.
    /// Used by the overlay to highlight the currently-spoken text.
    func setOnSegmentStart(_ callback: @escaping @Sendable @MainActor (String) -> Void) {
        onSegmentStart = callback
    }

    // MARK: - Streaming Playback

    /// Appends `text` to the sentence queue and starts the drain task if not already running.
    /// Non-async — the caller hops to the actor executor and returns immediately.
    /// Sentences play serially in the order they are enqueued.
    func enqueue(text: String, voice: String, speed: Float, backend: TtsBackend) {
        configure(backend: backend)
        let trimmed = Self.prepareForSpeech(text)
        guard !trimmed.isEmpty else { return }
        queuedSentences.append(trimmed)
        guard queueTask == nil else { return }
        let gen = generation
        queueTask = Task { await self.processQueue(generation: gen, voice: voice, speed: speed) }
    }

    /// Awaits completion of all queued sentences.
    /// Returns immediately if the queue is already idle.
    func waitForQueue() async {
        await queueTask?.value
    }

    /// Drains `queuedSentences` for playback generation `gen`.
    ///
    /// Invariant: every `await` must be followed by an `isLive(gen)` check before any write
    /// to `player`, `queuedSentences`, `queueTask`, or the highlight callback. A stale loop
    /// (one whose generation was superseded by `stop()`) touches nothing; `stop()` already
    /// cleared the queue and fired the end-of-playback callback on its behalf.
    private func processQueue(generation gen: UInt64, voice: String, speed: Float) async {
        defer {
            if gen == generation {
                queueTask = nil
                // Signal end of playback — clears overlay highlight.
                notifySegmentEnd()
            }
        }
        guard let provider else { return }
        do {
            try await ensureInitialized(provider: provider)
        } catch {
            if gen == generation {
                Self.log.error("TTS init failed, dropping queue: \(error.localizedDescription, privacy: .public)")
                queuedSentences.removeAll()
            }
            return
        }
        guard isLive(gen) else { return }

        // Prefetch buffer: while current audio plays, synthesize the next segment
        // concurrently. This eliminates the gap between segments when synthesis is
        // faster than playback (the common case for short text on Apple Silicon).
        var prefetched: (text: String, audio: Data)? = nil

        while isLive(gen), !queuedSentences.isEmpty || prefetched != nil {
            // Use prefetched audio if available; otherwise synthesize the current segment.
            let text: String
            let audio: Data
            if let p = prefetched {
                (text, audio) = p
                prefetched = nil
            } else {
                text = queuedSentences.removeFirst()
                Self.log.info("TTS synth [\(voice, privacy: .public)]: \(text.count) chars")
                do {
                    let start = ContinuousClock.now
                    audio = try await provider.synthesize(text: text, voice: voice, speed: speed)
                    let elapsed = ContinuousClock.now - start
                    Self.log.debug("TTS synth took \(elapsed, privacy: .public) for \(text.count) chars")
                } catch {
                    guard isLive(gen) else { return }
                    Self.log.error("TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard isLive(gen) else { return }
            }

            // Start playback and notify overlay for text highlighting.
            // No `await` between the liveness check above and these writes.
            player?.stop()
            player = try? AVAudioPlayer(data: audio)
            player?.play()
            let duration = player?.duration ?? 0
            Self.log.debug("TTS playing \(duration, privacy: .public)s of audio")
            notifySegment(text)

            // While audio plays, prefetch the next segment's synthesis.
            // Task.sleep yields the actor executor; synthesis runs on the provider's worker.
            if !queuedSentences.isEmpty {
                let next = queuedSentences.removeFirst()
                Self.log.info("TTS prefetch [\(voice, privacy: .public)]: \(next.count) chars")

                let prefetchTask = Task { [provider] () -> Data? in
                    let start = ContinuousClock.now
                    let result = try? await provider.synthesize(text: next, voice: voice, speed: speed)
                    Self.log.debug("TTS prefetch took \(ContinuousClock.now - start, privacy: .public)")
                    return result
                }

                if duration > 0 {
                    do { try await Task.sleep(for: .seconds(duration + 0.05)) }
                    catch { prefetchTask.cancel(); return }
                }
                guard isLive(gen) else { prefetchTask.cancel(); return }

                // Collect prefetched result — instant if synth finished during playback.
                let result = await prefetchTask.value
                guard isLive(gen) else { return }
                if let result { prefetched = (next, result) }
            } else if duration > 0 {
                // No next sentence yet — just await playback.
                // New sentences may arrive via enqueue() during sleep — the loop re-checks.
                do { try await Task.sleep(for: .seconds(duration + 0.05)) }
                catch { return }
            }
        }
    }

    // MARK: - Full-text Playback

    /// Synthesizes `text` as a single utterance and awaits completion.
    /// Stops any in-progress playback and queue first.
    /// Task cancellation propagates via `Task.sleep`.
    func speak(text: String, voice: String, speed: Float, backend: TtsBackend) async {
        stop()
        let gen = generation
        configure(backend: backend)
        let trimmed = Self.prepareForSpeech(text)
        guard !trimmed.isEmpty, let provider else { return }
        do {
            try await ensureInitialized(provider: provider)
            guard isLive(gen) else { return }
            let data = try await provider.synthesize(text: trimmed, voice: voice, speed: speed)
            guard isLive(gen) else { return }
            player?.stop()
            player = try? AVAudioPlayer(data: data)
            player?.play()
            // No segment highlight for full-text speak — highlighting only works
            // with streaming segments where there's dim/bright contrast.
            if let duration = player?.duration, duration > 0 {
                try? await Task.sleep(for: .seconds(duration + 0.1))
            }
        } catch {
            guard isLive(gen) else { return }
            Self.log.error("TTS speak failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops all playback and clears the sentence queue.
    ///
    /// Bumps `generation`, so any drain loop or `speak` suspended at an `await` exits
    /// without touching playback state. If something was active, fires the end-of-playback
    /// callback here (the stale loop no longer does); ConversationCoordinator relies on it
    /// to clear the highlighted segment.
    func stop() {
        generation &+= 1
        let wasActive = player != nil || queueTask != nil
        queuedSentences.removeAll()
        queueTask?.cancel()
        queueTask = nil
        player?.stop()
        player = nil
        if wasActive { notifySegmentEnd() }
    }

    /// `true` when the current provider is loaded and ready to synthesize.
    var isReady: Bool { provider?.isAvailable ?? false }

    // MARK: - Text Preparation

    /// Shared number formatter for spelling out numbers.
    private static let spellOutFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .spellOut
        fmt.locale = Locale(identifier: "en_US")
        return fmt
    }()

    /// Trims whitespace, expands acronyms to spaced letters, and converts digit
    /// sequences to words so TTS engines can pronounce them naturally.
    /// "LLM" → "L L M", "42" → "forty-two", "3.14" → "three point one four".
    static func prepareForSpeech(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // 1. Expand acronyms: 2-5 uppercase letters (not part of a longer word).
        //    "LLM" → "L L M", "SAE" → "S A E", "AI" → "A I"
        //    Excludes words like "The", "OR" that happen to be short caps in titles.
        let acronymPattern = try! NSRegularExpression(pattern: #"\b([A-Z]{2,5})\b"#)
        var result = trimmed
        let acronymRange = NSRange(result.startIndex..., in: result)
        for match in acronymPattern.matches(in: result, range: acronymRange).reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let acronym = String(result[swiftRange])
            // Skip common short words that happen to be all-caps
            let skipWords: Set<String> = ["OR", "AN", "AT", "BY", "DO", "GO", "IF",
                                          "IN", "IS", "IT", "MY", "NO", "OF", "ON",
                                          "SO", "TO", "UP", "US", "WE", "AM", "AS",
                                          "BE", "HE", "ME", "OK"]
            guard !skipWords.contains(acronym) else { continue }
            let spaced = acronym.map { String($0) }.joined(separator: " ")
            result.replaceSubrange(swiftRange, with: spaced)
        }

        // 2. Spell out numbers: "42" → "forty-two"
        let numberPattern = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
        let numRange = NSRange(result.startIndex..., in: result)
        for match in numberPattern.matches(in: result, range: numRange).reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let numStr = String(result[swiftRange])
            if let number = Double(numStr),
               let spelled = spellOutFormatter.string(from: NSNumber(value: number)) {
                result.replaceSubrange(swiftRange, with: spelled)
            }
        }
        return result
    }

    // MARK: - Private

    private func ensureInitialized(provider: any TTSProvider) async throws {
        // Already ready — fast path.
        guard !provider.isAvailable else { return }

        // Another caller is already initializing — join their task and wait.
        if let existing = initTask {
            try await existing.value
            return
        }

        // Start initialization; store the task so concurrent callers can join.
        let task = Task { try await provider.initialize() }
        initTask = task
        // Only clear our own task: a `configure()` switch mid-init may have installed a new one.
        defer { if initTask == task { initTask = nil } }
        try await task.value
    }

    private func isLive(_ gen: UInt64) -> Bool {
        gen == generation && !Task.isCancelled
    }

    /// Fires the highlight callback with `text` (segment started playing).
    private func notifySegment(_ text: String) {
        if let callback = onSegmentStart {
            Task { @MainActor in callback(text) }
        }
    }

    /// Fires the highlight callback with "" (playback ended) — clears overlay highlight.
    private func notifySegmentEnd() {
        notifySegment("")
    }
}

// MARK: - Sentence Splitting

extension String {
    /// Splits text into chunks for TTS streaming.
    ///
    /// Strategy: first chunk is short (~1 sentence, ≥30 chars) for fast playback start.
    /// Subsequent chunks are larger (~2-3 sentences, ≥120 chars) so the TTS model has
    /// enough context for natural prosody — avoids the robotic per-sentence reset.
    func splitIntoSentences() -> [String] {
        var chunks: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let isFirst = { chunks.isEmpty }
        // First chunk: low threshold for fast start. Later: larger for natural flow.
        let minChars = { isFirst() ? 30 : 120 }

        for char in self {
            current.append(char)
            if terminators.contains(char) && current.count >= minChars() {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = ""
            } else if char == "\n" && current.count >= max(minChars(), 50) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }
        return chunks
    }
}
