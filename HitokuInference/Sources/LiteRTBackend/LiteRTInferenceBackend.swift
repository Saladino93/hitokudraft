import Foundation
import CoreGraphics
import CLiteRTEngine
import HitokuInference

/// LiteRT-LM-based inference backend.
///
/// Wraps the LiteRT-LM C API via dynamic loading (`dlopen`) to provide native
/// multimodal inference supporting text, audio, and images (e.g. Gemma 4 E2B).
///
/// The dylibs (`liblitert_lm_engine.dylib`, `libLiteRt.dylib`,
/// `libLiteRtMetalAccelerator.dylib`, `libGemmaModelConstraintProvider.dylib`)
/// must be in the app's Frameworks/.
public final class LiteRTInferenceBackend: @unchecked Sendable {

    // MARK: - State

    private var engine: OpaquePointer?       // LiteRtLmEngine*
    fileprivate var activeConversation: OpaquePointer?  // Reused across calls
    fileprivate var activeConvConfig: OpaquePointer?
    fileprivate var activeSessionConfig: OpaquePointer?
    private var funcs: LiteRTFunctions?
    private var config: BackendConfig = .init()

    /// Protects all mutable state from concurrent access.
    /// The C callback runs on LiteRT's serial queue (Thread 150); generate/cancel/unload
    /// may run on any Swift thread. This lock prevents races on conversation pointers.
    private let lock = NSLock()

    // MARK: - Init

    public init() {
        self.funcs = LiteRTFunctions.resolve()
    }

    /// Whether the LiteRT dylib is available on this system.
    public var isRuntimeAvailable: Bool { funcs != nil }

    // MARK: - Helpers

    private var backendString: String {
        config.extra["backend"] as? String ?? "gpu"
    }
}

// MARK: - InferenceBackend

extension LiteRTInferenceBackend: InferenceBackend {

    public var supportedModalities: Set<InputModality> { [.text, .audio, .image] }

    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
    }

    public func loadModel(at path: String, config: BackendConfig) async throws {
        guard let funcs else { throw LiteRTError.runtimeNotAvailable }

        unload()
        lock.lock()
        self.config = config
        lock.unlock()

        // Suppress verbose logging (2 = ERROR only)
        funcs.setMinLogLevel(2)

        let backend = backendString
        let visionBackend = config.extra["visionBackend"] as? String ?? "gpu"
        let audioBackend = config.extra["audioBackend"] as? String ?? "cpu"

        guard let settings = funcs.engineSettingsCreate(path, backend, visionBackend, audioBackend) else {
            throw LiteRTError.failedToCreateSettings
        }
        defer { funcs.engineSettingsDelete(settings) }

        if let cacheDir = config.extra["cacheDir"] as? String {
            funcs.engineSettingsSetCacheDir(settings, cacheDir)
        }

        guard let eng = funcs.engineCreate(settings) else {
            throw LiteRTError.failedToCreateEngine
        }
        lock.lock()
        self.engine = eng
        lock.unlock()
    }

    public func unload() {
        lock.lock()
        // Cancel in-flight generation (does not nil the conversation)
        if let conversation = activeConversation, let funcs {
            funcs.conversationCancelProcess(conversation)
        }
        // Now delete the conversation — safe because conversationSendMessageStream
        // returns after cancel, and we hold the lock so no new generate() can start.
        if let conv = activeConversation, let funcs {
            funcs.conversationDelete(conv)
        }
        activeConversation = nil
        if let cc = activeConvConfig, let funcs { funcs.conversationConfigDelete(cc) }
        if let sc = activeSessionConfig, let funcs { funcs.sessionConfigDelete(sc) }
        activeConvConfig = nil
        activeSessionConfig = nil
        if let engine, let funcs {
            funcs.engineDelete(engine)
        }
        engine = nil
        lock.unlock()
    }

    /// Cancel any in-flight generation. Safe to call even if nothing is running.
    /// Does NOT destroy the conversation — it is reused for subsequent generate() calls.
    /// Only `unload()` deletes the conversation.
    public func cancelGeneration() {
        lock.lock()
        if let conversation = activeConversation, let funcs {
            funcs.conversationCancelProcess(conversation)
        }
        // DO NOT nil activeConversation here. The conversation is reused across calls.
        // Nil-ing it would leak the C object (no conversationDelete) and force
        // a new conversation on the next generate(), violating LiteRT's single-session rule.
        lock.unlock()
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let engine = self.engine
        let funcs = self.funcs
        lock.unlock()

        guard let engine, let funcs else {
            return AsyncThrowingStream {
                $0.finish(throwing: funcs == nil
                    ? LiteRTError.runtimeNotAvailable
                    : LiteRTError.engineNotLoaded)
            }
        }

        return AsyncThrowingStream { [weak self] continuation in

            // When the Swift consumer cancels (e.g., voiceEditTask.cancel()),
            // cancel the C-level generation so it stops producing tokens.
            continuation.onTermination = { @Sendable _ in
                self?.cancelGeneration()
            }

            Task.detached { [weak self] in
                print("[LiteRT] generate() called")
                print("[LiteRT] audio: \(request.audio != nil ? "\(request.audio!.count) bytes" : "nil"), images: \(request.images?.count ?? 0)")

                guard let self else {
                    continuation.finish()
                    return
                }

                // Cancel any in-flight generation before starting a new one.
                // This ensures only one conversationSendMessageStream runs at a time.
                self.cancelGeneration()

                self.lock.lock()

                // Fresh conversation each time — prevents context accumulation
                // that causes the model to degrade after many interactions.
                if let oldConv = self.activeConversation {
                    funcs.conversationDelete(oldConv)
                    self.activeConversation = nil
                    if let cfg = self.activeConvConfig { funcs.conversationConfigDelete(cfg) }
                    self.activeConvConfig = nil
                    if let scfg = self.activeSessionConfig { funcs.sessionConfigDelete(scfg) }
                    self.activeSessionConfig = nil
                }
                do {
                    print("[LiteRT] creating new conversation")
                    let sessionConfig = funcs.sessionConfigCreate()
                    if let sessionConfig {
                        funcs.sessionConfigSetMaxOutputTokens(sessionConfig, Int32(request.maxTokens))
                        let effectiveTemp = max(request.temperature, 0.5)
                        var samplerParams = LiteRtLmSamplerParams(
                            type: kTopP, top_k: 40,
                            top_p: request.topP ?? 0.95,
                            temperature: effectiveTemp, seed: 0
                        )
                        funcs.sessionConfigSetSamplerParams(sessionConfig, &samplerParams)
                    }

                    let systemCStr: UnsafeMutablePointer<CChar>? = request.systemPrompt.flatMap {
                        strdup($0)
                    }

                    let convConfig = funcs.conversationConfigCreate(
                        engine, sessionConfig, systemCStr, nil, nil, false
                    )

                    guard let conversation = funcs.conversationCreate(engine, convConfig) else {
                        if let convConfig { funcs.conversationConfigDelete(convConfig) }
                        if let sessionConfig { funcs.sessionConfigDelete(sessionConfig) }
                        if let systemCStr { free(systemCStr) }
                        self.lock.unlock()
                        continuation.finish(throwing: LiteRTError.failedToCreateConversation)
                        return
                    }

                    self.activeConversation = conversation
                    self.activeConvConfig = convConfig
                    self.activeSessionConfig = sessionConfig
                    if let systemCStr { free(systemCStr) }
                }

                guard let conversation = self.activeConversation else {
                    self.lock.unlock()
                    continuation.finish(throwing: LiteRTError.failedToCreateConversation)
                    return
                }

                self.lock.unlock()

                // Build the message JSON and strdup it. Ownership stays HERE —
                // we free it after conversationSendMessageStream returns, because the
                // C library may still reference the pointer after callbacks fire.
                let (messageJSON, tempFiles) = Self.buildMessageJSON(request: request)
                let messageCStr = strdup(messageJSON)

                print("[LiteRT] sending: \(String(cString: messageCStr!))")

                let ctx = Unmanaged.passRetained(StreamContext(
                    continuation: continuation
                )).toOpaque()

                let result = funcs.conversationSendMessageStream(
                    conversation, messageCStr, nil,
                    { callbackData, chunk, isFinal, errorMsg in
                        guard let callbackData else { return }
                        let streamCtx = Unmanaged<StreamContext>.fromOpaque(callbackData)
                            .takeUnretainedValue()

                        // Skip late chunks after early completion (repetition, cancellation).
                        // Still process final/error to ensure the Unmanaged reference is released.
                        if streamCtx.isCompleted && !isFinal && errorMsg == nil {
                            return
                        }

                        if let errorMsg {
                            print("[LiteRT] stream error: \(String(cString: errorMsg))")
                            if !streamCtx.isCompleted {
                                streamCtx.continuation.finish(
                                    throwing: LiteRTError.generationError(String(cString: errorMsg))
                                )
                                streamCtx.isCompleted = true
                            }
                            streamCtx.releaseOnce(callbackData)
                            return
                        }

                        if isFinal {
                            print("[LiteRT] stream finished")
                            if !streamCtx.isCompleted {
                                streamCtx.continuation.finish()
                                streamCtx.isCompleted = true
                            }
                            streamCtx.releaseOnce(callbackData)
                            return
                        }

                        if let chunk {
                            let raw = String(cString: chunk)
                            if let text = extractLiteRTText(raw) {
                                // Repetition detection — mark completed but do NOT release.
                                // The final callback will release the context safely.
                                if streamCtx.checkRepetition(text) {
                                    print("[LiteRT] repetition detected, stopping")
                                    streamCtx.isCompleted = true
                                    streamCtx.continuation.finish()
                                    return
                                }
                                streamCtx.continuation.yield(text)
                            }
                        }
                    },
                    ctx
                )

                print("[LiteRT] conversationSendMessageStream returned: \(result)")

                // Free the message string AFTER the blocking call returns.
                // The C library may reference it during/after callbacks for conversation history.
                if let messageCStr { free(messageCStr) }

                // Clean up temp files (audio/image) now that LiteRT has consumed them.
                for url in tempFiles {
                    try? FileManager.default.removeItem(at: url)
                }

                if result != 0 {
                    print("[LiteRT] ERROR: stream failed with code \(result)")
                    // Non-zero return = stream never started, callback was not invoked.
                    // Release the StreamContext ourselves.
                    let streamCtx = Unmanaged<StreamContext>.fromOpaque(ctx).takeRetainedValue()
                    streamCtx.isCompleted = true
                    continuation.finish(throwing: LiteRTError.streamStartFailed)
                }
            }
        }
    }

    // MARK: - JSON Helpers

    /// Build message JSON using JSONSerialization for proper escaping of all characters.
    /// Hand-crafted JSON breaks on real-world text (French accents, tabs, control chars, etc.)
    /// Returns (json, tempFileURLs) — caller must delete temp files after the C call returns.
    private static func buildMessageJSON(request: InferenceRequest) -> (String, [URL]) {
        var contentParts: [[String: String]] = []
        var tempFiles: [URL] = []

        if let text = request.text, !text.isEmpty {
            contentParts.append(["type": "text", "text": text])
        }

        // Images: write to temp file, use "path" key (LiteRT memory-maps it)
        if let images = request.images {
            for (i, image) in images.enumerated() {
                if let pngData = Self.pngData(from: image) {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("litert_img_\(ProcessInfo.processInfo.processIdentifier)_\(i).png")
                    try? pngData.write(to: tempURL)
                    contentParts.append(["type": "image", "path": tempURL.path])
                    tempFiles.append(tempURL)
                }
            }
        }

        // Audio: write to temp file, use "path" key ("blob" segfaults for large data)
        if let audio = request.audio {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("litert_audio_\(ProcessInfo.processInfo.processIdentifier).wav")
            try? audio.write(to: tempURL)
            contentParts.append(["type": "audio", "path": tempURL.path])
            tempFiles.append(tempURL)
        }

        let message: [String: Any] = [
            "role": "user",
            "content": contentParts
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            // Fallback: simple text-only message
            let fallbackText = (request.text ?? "").replacingOccurrences(of: "\"", with: "'")
            return ("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(fallbackText)\"}]}", tempFiles)
        }
        return (json, tempFiles)
    }

    /// Convert CGImage to PNG data for base64 encoding.
    private static func pngData(from cgImage: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

// MARK: - NSBitmapImageRep import

#if canImport(AppKit)
import AppKit
#endif

// MARK: - JSON parsing (standalone, usable from C callbacks)

/// Extract text from LiteRT's streaming JSON response.
/// Format: {"role":"assistant","content":[{"type":"text","text":"Hello"}]}
private func extractLiteRTText(_ json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = obj["content"] as? [[String: Any]] else {
        return json.isEmpty ? nil : json
    }
    var text = ""
    for part in content {
        if let t = part["text"] as? String { text += t }
    }
    return text.isEmpty ? nil : text
}

// MARK: - Stream Context

/// Holds per-generation state for the C callback.
///
/// Lifetime: created with `Unmanaged.passRetained()` before `conversationSendMessageStream`,
/// released exactly once by `releaseOnce()` in the final/error callback. The `messageCStr`
/// is NOT owned here — it is freed by the caller after the blocking C call returns.
private final class StreamContext: @unchecked Sendable {
    let continuation: AsyncThrowingStream<String, Error>.Continuation

    /// True after `continuation.finish()` was called (normal end, error, or early stop).
    /// Subsequent chunk callbacks are skipped; the final callback still runs to release.
    var isCompleted = false

    // Repetition detection — same sliding window as MLXInferenceBackend
    var recentChunks: [String] = []
    var isDegenerate = false

    /// Guards against double-release of the Unmanaged reference.
    /// The C library may fire multiple terminal callbacks (error + final, or cancel + final).
    private let releaseLock = NSLock()
    private var released = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
        self.recentChunks.reserveCapacity(21)
    }

    /// Returns true if the last 20 chunks are degenerate (3 or fewer unique).
    func checkRepetition(_ chunk: String) -> Bool {
        recentChunks.append(chunk)
        if recentChunks.count > 20 { recentChunks.removeFirst() }
        if recentChunks.count == 20, Set(recentChunks).count <= 3 {
            isDegenerate = true
            return true
        }
        return false
    }

    /// Release the Unmanaged reference exactly once. Safe to call from multiple callbacks.
    func releaseOnce(_ callbackData: UnsafeMutableRawPointer) {
        releaseLock.lock()
        guard !released else {
            releaseLock.unlock()
            return
        }
        released = true
        releaseLock.unlock()
        Unmanaged<StreamContext>.fromOpaque(callbackData).release()
    }
}

// MARK: - Errors

public enum LiteRTError: LocalizedError {
    case runtimeNotAvailable
    case failedToCreateSettings
    case failedToCreateEngine
    case engineNotLoaded
    case failedToCreateConversation
    case streamStartFailed
    case generationError(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotAvailable:
            return "LiteRT runtime not available. Ensure liblitert_lm_engine.dylib is in app Frameworks/."
        case .failedToCreateSettings:
            return "Failed to create LiteRT engine settings."
        case .failedToCreateEngine:
            return "Failed to create LiteRT engine. Check model path and backend."
        case .engineNotLoaded:
            return "No LiteRT engine is loaded. Call loadModel(at:config:) first."
        case .failedToCreateConversation:
            return "Failed to create LiteRT conversation."
        case .streamStartFailed:
            return "Failed to start LiteRT streaming generation."
        case .generationError(let msg):
            return "LiteRT generation error: \(msg)"
        }
    }
}
