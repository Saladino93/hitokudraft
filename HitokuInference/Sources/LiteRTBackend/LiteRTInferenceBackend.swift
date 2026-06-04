import Foundation
import CoreGraphics
import LiteRTLM
import HitokuInference

#if canImport(AppKit)
import AppKit
#endif

/// LiteRT-LM inference backend, built on Google's official Swift SDK.
///
/// Replaces the previous hand-rolled C binding (`dlopen` + `dlsym` + manual
/// `Unmanaged` callback contexts). The SDK ships a prebuilt, code-signed
/// `CLiteRTLM_mac.xcframework` via SwiftPM, and exposes an `actor`-isolated
/// `Engine` plus a `Conversation` whose `sendMessageStream` is a native
/// `AsyncThrowingStream` — so the entire lifecycle is ARC- and actor-managed
/// rather than owned by hand.
///
/// Supports text, audio, and image inputs (e.g. Gemma 4 E2B/E4B multimodal).
public final class LiteRTInferenceBackend: @unchecked Sendable {

    /// All mutable state lives behind a lock in this holder. Concurrent
    /// closures (`onTermination`, the generation `Task`) capture `store` — a
    /// `Sendable let` — instead of `self`, which keeps them off Swift's
    /// captured-`self` concurrency diagnostics.
    private let store = Store()

    public init() {}

    /// The official SDK is statically linked via the SwiftPM binary target, so
    /// the runtime is always present. Retained for source-compatibility with
    /// the previous `dlopen`-based backend (callers still gate on this).
    public var isRuntimeAvailable: Bool { true }
}

// MARK: - InferenceBackend

extension LiteRTInferenceBackend: InferenceBackend {

    public var supportedModalities: Set<InputModality> { [.text, .audio, .image] }

    public var isLoaded: Bool { store.isLoaded }

    public func loadModel(at path: String, config: BackendConfig) async throws {
        unload()

        // Backend selection (defaults match the previous C-API behavior:
        // GPU/Metal for text + vision, CPU for the audio front-end).
        let backend = Self.parseBackend(config.extra["backend"] as? String ?? "gpu")
        let visionBackend = Self.parseBackend(config.extra["visionBackend"] as? String ?? "gpu")
        let audioBackend = Self.parseBackend(config.extra["audioBackend"] as? String ?? "cpu")
        let cacheDir = config.extra["cacheDir"] as? String
        // Total sequence budget (prompt + generated output), set once at engine
        // creation. 8192 gives headroom for editing long transcripts; Gemma 4
        // supports well beyond this. Generation stops at EOS, with the repetition
        // guard below as a backstop.
        let maxNumTokens = config.extra["maxNumTokens"] as? Int ?? 8192

        let engineConfig = try EngineConfig(
            modelPath: path,
            backend: backend,
            visionBackend: visionBackend,
            audioBackend: audioBackend,
            maxNumTokens: maxNumTokens,
            cacheDir: cacheDir
        )

        let engine = Engine(engineConfig: engineConfig)
        try await engine.initialize()
        store.install(engine: engine)
    }

    public func unload() {
        store.clear()
    }

    /// Cancel any in-flight generation. Safe to call when nothing is running.
    public func cancelGeneration() {
        store.cancelActiveConversation()
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        guard let engine = store.currentEngine else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTError.engineNotLoaded) }
        }

        // Capture the lock-backed store, never `self`.
        let store = self.store

        return AsyncThrowingStream { continuation in

            // When the Swift consumer cancels (e.g. voiceEditTask.cancel()),
            // stop the native generation.
            continuation.onTermination = { @Sendable _ in
                store.cancelActiveConversation()
            }

            Task {
                do {
                    let sampler = try SamplerConfig(
                        topK: 40,
                        topP: request.topP ?? 0.95,
                        // Floor the temperature: greedy decoding (0.0) tends to
                        // loop on these models. Matches prior behavior.
                        temperature: max(request.temperature, 0.5)
                    )

                    let convConfig = ConversationConfig(
                        systemMessage: request.systemPrompt.map { Message($0, role: .system) },
                        samplerConfig: sampler
                    )

                    // Fresh conversation per call — prevents context accumulation
                    // that degrades quality after many interactions.
                    let conversation = try await engine.createConversation(with: convConfig)
                    store.setActiveConversation(conversation)
                    defer { store.setActiveConversation(nil) }

                    let message = Self.buildMessage(from: request)

                    var window = RepetitionWindow()
                    for try await chunk in conversation.sendMessageStream(message) {
                        let text = chunk.toString
                        guard !text.isEmpty else { continue }
                        if window.isDegenerate(text) { break }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Thread-safe state holder

extension LiteRTInferenceBackend {

    /// Owns the engine and the in-flight conversation behind an `NSLock`.
    /// All access is synchronous, so the lock never crosses an `await`.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var engine: Engine?
        private var activeConversation: Conversation?
        private var loaded = false

        var isLoaded: Bool {
            lock.lock(); defer { lock.unlock() }
            return loaded
        }

        var currentEngine: Engine? {
            lock.lock(); defer { lock.unlock() }
            return engine
        }

        func install(engine: Engine) {
            lock.lock()
            self.engine = engine
            self.loaded = true
            lock.unlock()
        }

        func clear() {
            lock.lock()
            try? activeConversation?.cancel()
            activeConversation = nil
            engine = nil
            loaded = false
            lock.unlock()
        }

        func setActiveConversation(_ conversation: Conversation?) {
            lock.lock()
            activeConversation = conversation
            lock.unlock()
        }

        func cancelActiveConversation() {
            lock.lock()
            try? activeConversation?.cancel()
            lock.unlock()
        }
    }
}

// MARK: - Helpers

extension LiteRTInferenceBackend {

    private static func parseBackend(_ value: String) -> Backend {
        value.lowercased() == "gpu" ? .gpu : .cpu()
    }

    /// Assemble a multimodal `Message` from the request.
    ///
    /// Order (text → image → audio) matches the prior C-API path. Media is
    /// passed as `Data` via the SDK's native `imageData`/`audioData` cases —
    /// no more hand-built JSON or temp files. If large-audio inputs ever
    /// regress, switch those to `.audioFile`/`.imageFile` with a temp file.
    private static func buildMessage(from request: InferenceRequest) -> Message {
        var contents: [Content] = []

        if let text = request.text, !text.isEmpty {
            contents.append(.text(text))
        }
        if let images = request.images {
            for image in images {
                if let png = pngData(from: image) {
                    contents.append(.imageData(png))
                }
            }
        }
        if let audio = request.audio {
            contents.append(.audioData(audio))
        }
        if contents.isEmpty {
            contents.append(.text(""))
        }

        return Message(contents: contents, role: .user)
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

// MARK: - Repetition guard

/// Detects degenerate loops (model repeating a tiny set of chunks).
/// Backstop for runaway generation, independent of the engine's own limits.
private struct RepetitionWindow {
    private var recent: [String] = []

    /// True once the last 20 chunks collapse to 3 or fewer unique values.
    mutating func isDegenerate(_ chunk: String) -> Bool {
        recent.append(chunk)
        if recent.count > 20 { recent.removeFirst() }
        return recent.count == 20 && Set(recent).count <= 3
    }
}

// MARK: - Errors

public enum LiteRTError: LocalizedError {
    case engineNotLoaded
    case generationError(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotLoaded:
            return "No LiteRT engine is loaded. Call loadModel(at:config:) first."
        case .generationError(let msg):
            return "LiteRT generation error: \(msg)"
        }
    }
}
