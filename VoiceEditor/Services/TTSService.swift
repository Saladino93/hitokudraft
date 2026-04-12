import Foundation
import AVFoundation
import FluidAudio
import os

// MARK: - TTSProvider Protocol

/// Abstract TTS synthesis backend.
///
/// Conforming types are stored exclusively within `TTSService`'s actor isolation,
/// so non-Sendable concrete types (KokoroTtsManager, PocketTtsManager) are safe.
///
/// To add a new backend: conform to this protocol, add a case to `TtsBackend`,
/// and add a branch in `TTSService.configure(backend:)`. No other changes needed.
protocol TTSProvider: AnyObject {
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

// MARK: - Kokoro Backend

/// Phoneme-based, multi-voice synthesis via Kokoro 82M CoreML.
/// American English voices are production-tested; other languages are experimental.
/// Synthesizes all frames at once — low latency for short to medium text.
final class KokoroTTSProvider: TTSProvider {

    private let manager: KokoroTtsManager

    init(cacheDirectory: URL? = nil) {
        manager = KokoroTtsManager(directory: cacheDirectory)
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice, voiceSpeed: speed)
    }

    var isAvailable: Bool { manager.isAvailable }

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

    private let manager: PocketTtsManager
    /// Local flag because PocketTtsManager is an actor; bridging `isAvailable`
    /// synchronously avoids an async hop on every `speak()` call.
    private var initialized = false

    init(cacheDirectory: URL? = nil) {
        manager = PocketTtsManager(directory: cacheDirectory)
    }

    func initialize() async throws {
        try await manager.initialize()
        initialized = true
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        // PocketTTS has no speed parameter — `speed` is intentionally ignored.
        try await manager.synthesize(text: text, voice: voice)
    }

    var isAvailable: Bool { initialized }

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

    static let shared = TTSService()

    private var provider: (any TTSProvider)?
    private var currentBackend: TtsBackend?
    /// Shared initialization task — concurrent callers await the same task
    /// instead of skipping (which caused "model not initialized" errors).
    private var initTask: Task<Void, any Error>?
    /// Retained to keep playback alive. Replaced on each new utterance.
    private var player: AVAudioPlayer?
    /// Fires on @MainActor when a new segment starts playing. Set by the coordinator
    /// to drive overlay text highlighting. Cleared automatically when playback stops.
    private var onSegmentStart: (@Sendable @MainActor (String) -> Void)?

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
        let dir = cacheRoot
        provider = switch backend {
        case .kokoro:    KokoroTTSProvider(cacheDirectory: dir)
        case .pocketTts: PocketTTSProvider(cacheDirectory: dir)
        }
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
        queueTask = Task { await self.processQueue(voice: voice, speed: speed) }
    }

    /// Awaits completion of all queued sentences.
    /// Returns immediately if the queue is already idle.
    func waitForQueue() async {
        await queueTask?.value
    }

    private func processQueue(voice: String, speed: Float) async {
        defer {
            queueTask = nil
            // Signal end of playback — clears overlay highlight.
            if let callback = onSegmentStart {
                Task { @MainActor in callback("") }
            }
        }
        guard let provider else { return }
        do {
            try await ensureInitialized(provider: provider)
        } catch {
            Self.log.error("TTS init failed, dropping queue: \(error.localizedDescription, privacy: .public)")
            queuedSentences.removeAll()
            return
        }

        // Prefetch buffer: while current audio plays, synthesize the next segment
        // concurrently. This eliminates the gap between segments when synthesis is
        // faster than playback (the common case for short text on Apple Silicon).
        var prefetchedAudio: Data? = nil
        var prefetchedText: String = ""
        var currentSegmentText: String = ""

        while !queuedSentences.isEmpty || prefetchedAudio != nil {
            guard !Task.isCancelled else { break }

            // Use prefetched audio if available; otherwise synthesize the current segment.
            let audioData: Data
            if let prefetched = prefetchedAudio {
                audioData = prefetched
                prefetchedAudio = nil
                currentSegmentText = prefetchedText
            } else {
                let sentence = queuedSentences.removeFirst()
                currentSegmentText = sentence
                Self.log.info("TTS synth [\(voice, privacy: .public)]: \(sentence.prefix(60), privacy: .public)")
                do {
                    let start = ContinuousClock.now
                    audioData = try await provider.synthesize(text: sentence, voice: voice, speed: speed)
                    let elapsed = ContinuousClock.now - start
                    Self.log.debug("TTS synth took \(elapsed, privacy: .public) for \(sentence.count) chars")
                } catch {
                    guard !Task.isCancelled else { break }
                    Self.log.error("TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            // Start playback and notify overlay for text highlighting.
            player?.stop()
            player = try? AVAudioPlayer(data: audioData)
            player?.play()
            let playDuration = player?.duration ?? 0
            Self.log.debug("TTS playing \(playDuration, privacy: .public)s of audio")
            if let callback = onSegmentStart {
                Task { @MainActor in callback(currentSegmentText) }
            }

            // While audio plays, prefetch the next segment's synthesis.
            // Task.sleep yields the actor executor → the prefetch Task runs concurrently
            // because CoreML inference happens off-actor on its own thread.
            if !queuedSentences.isEmpty {
                let nextSentence = queuedSentences.removeFirst()
                Self.log.info("TTS prefetch [\(voice, privacy: .public)]: \(nextSentence.prefix(60), privacy: .public)")

                let prefetchTask = Task { [provider] () -> Data? in
                    let start = ContinuousClock.now
                    let result = try? await provider.synthesize(
                        text: nextSentence, voice: voice, speed: speed
                    )
                    Self.log.debug("TTS prefetch took \(ContinuousClock.now - start, privacy: .public)")
                    return result
                }

                if playDuration > 0 {
                    do { try await Task.sleep(for: .seconds(playDuration + 0.05)) }
                    catch { prefetchTask.cancel(); break }
                }

                // Collect prefetched result — instant if synth finished during playback.
                prefetchedAudio = await prefetchTask.value
                prefetchedText = nextSentence
            } else {
                // No next sentence yet — just await playback.
                if playDuration > 0 {
                    do { try await Task.sleep(for: .seconds(playDuration + 0.05)) }
                    catch { break }
                }
                // New sentences may have arrived via enqueue() during sleep — loop will check.
            }
        }
    }

    // MARK: - Full-text Playback

    /// Synthesizes `text` as a single utterance and awaits completion.
    /// Stops any in-progress queue first.
    /// Task cancellation propagates via `Task.sleep`.
    func speak(text: String, voice: String, speed: Float, backend: TtsBackend) async {
        // Clear any streaming queue before speaking the full text.
        queuedSentences.removeAll()
        queueTask?.cancel()
        queueTask = nil
        configure(backend: backend)
        let trimmed = Self.prepareForSpeech(text)
        guard !trimmed.isEmpty, let provider else { return }
        do {
            try await ensureInitialized(provider: provider)
            let data = try await provider.synthesize(text: trimmed, voice: voice, speed: speed)
            player?.stop()
            player = try? AVAudioPlayer(data: data)
            player?.play()
            // No segment highlight for full-text speak — highlighting only works
            // with streaming segments where there's dim/bright contrast.
            if let duration = player?.duration, duration > 0 {
                try? await Task.sleep(for: .seconds(duration + 0.1))
            }
        } catch {
            Self.log.error("TTS speak failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops all playback and clears the sentence queue.
    func stop() {
        queuedSentences.removeAll()
        queueTask?.cancel()
        queueTask = nil
        player?.stop()
        player = nil
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
        defer { initTask = nil }
        try await task.value
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
