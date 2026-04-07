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

    public var isLoaded: Bool { engine != nil }

    public func loadModel(at path: String, config: BackendConfig) async throws {
        guard let funcs else { throw LiteRTError.runtimeNotAvailable }

        unload()
        self.config = config

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
        self.engine = eng
    }

    public func unload() {
        cancelGeneration()
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
    }

    /// Cancel any in-flight generation. Safe to call even if nothing is running.
    public func cancelGeneration() {
        if let conversation = activeConversation, let funcs {
            funcs.conversationCancelProcess(conversation)
        }
        activeConversation = nil
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        guard let engine, let funcs else {
            return AsyncThrowingStream {
                $0.finish(throwing: self.funcs == nil
                    ? LiteRTError.runtimeNotAvailable
                    : LiteRTError.engineNotLoaded)
            }
        }

        return AsyncThrowingStream { [weak self] continuation in
            Task.detached {
                print("[LiteRT] generate() called")
                print("[LiteRT] audio: \(request.audio != nil ? "\(request.audio!.count) bytes" : "nil"), images: \(request.images?.count ?? 0)")

                // Reuse existing conversation (LiteRT only supports one session at a time).
                // Create on first call, reuse for subsequent calls.
                if self?.activeConversation == nil {
                    print("[LiteRT] creating new conversation")
                    let sessionConfig = funcs.sessionConfigCreate()
                    if let sessionConfig {
                        funcs.sessionConfigSetMaxOutputTokens(sessionConfig, Int32(request.maxTokens))
                        var samplerParams = LiteRtLmSamplerParams(
                            type: kTopP, top_k: 40,
                            top_p: request.topP ?? 0.9,
                            temperature: request.temperature, seed: 0
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
                        continuation.finish(throwing: LiteRTError.failedToCreateConversation)
                        return
                    }

                    self?.activeConversation = conversation
                    self?.activeConvConfig = convConfig
                    self?.activeSessionConfig = sessionConfig
                    if let systemCStr { free(systemCStr) }
                } else {
                    print("[LiteRT] reusing existing conversation")
                }

                guard let conversation = self?.activeConversation else {
                    continuation.finish(throwing: LiteRTError.failedToCreateConversation)
                    return
                }
                let messageCStr = strdup(Self.buildMessageJSON(request: request))

                print("[LiteRT] sending: \(String(cString: messageCStr!))")

                // StreamContext owns only the message string. Conversation is reused.
                let ctx = Unmanaged.passRetained(StreamContext(
                    continuation: continuation,
                    messageCStr: messageCStr
                )).toOpaque()

                let result = funcs.conversationSendMessageStream(
                    conversation, messageCStr, nil,
                    { callbackData, chunk, isFinal, errorMsg in
                        guard let callbackData else { return }
                        let streamCtx = Unmanaged<StreamContext>.fromOpaque(callbackData)
                            .takeUnretainedValue()

                        if let errorMsg {
                            print("[LiteRT] stream error: \(String(cString: errorMsg))")
                            streamCtx.continuation.finish(
                                throwing: LiteRTError.generationError(String(cString: errorMsg))
                            )
                            streamCtx.cleanup()
                            Unmanaged<StreamContext>.fromOpaque(callbackData).release()
                            return
                        }

                        if isFinal {
                            print("[LiteRT] stream finished")
                            streamCtx.continuation.finish()
                            streamCtx.cleanup()
                            Unmanaged<StreamContext>.fromOpaque(callbackData).release()
                            return
                        }

                        if let chunk {
                            // LiteRT streams JSON: {"role":"assistant","content":[{"type":"text","text":"Hello"}]}
                            let raw = String(cString: chunk)
                            if let text = extractLiteRTText(raw) {
                                streamCtx.continuation.yield(text)
                            }
                        }
                    },
                    ctx
                )

                print("[LiteRT] conversationSendMessageStream returned: \(result)")
                if result != 0 {
                    print("[LiteRT] ERROR: stream failed with code \(result)")
                    // Stream didn't start — clean up here
                    let streamCtx = Unmanaged<StreamContext>.fromOpaque(ctx).takeRetainedValue()
                    streamCtx.cleanup()
                    continuation.finish(throwing: LiteRTError.streamStartFailed)
                }
                // Do NOT clean up here — the callback handles it when the stream ends.
            }
        }
    }

    // MARK: - JSON Helpers

    /// Build message JSON using JSONSerialization for proper escaping of all characters.
    /// Hand-crafted JSON breaks on real-world text (French accents, tabs, control chars, etc.)
    private static func buildMessageJSON(request: InferenceRequest) -> String {
        var contentParts: [[String: String]] = []

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
                }
            }
        }

        // Audio: write to temp file, use "path" key ("blob" segfaults for large data)
        if let audio = request.audio {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("litert_audio_\(ProcessInfo.processInfo.processIdentifier).wav")
            try? audio.write(to: tempURL)
            contentParts.append(["type": "audio", "path": tempURL.path])
        }

        let message: [String: Any] = [
            "role": "user",
            "content": contentParts
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            // Fallback: simple text-only message
            let fallbackText = (request.text ?? "").replacingOccurrences(of: "\"", with: "'")
            return "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(fallbackText)\"}]}"
        }
        return json
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

private final class StreamContext: @unchecked Sendable {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    let messageCStr: UnsafeMutablePointer<CChar>?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation,
         messageCStr: UnsafeMutablePointer<CChar>?) {
        self.continuation = continuation
        self.messageCStr = messageCStr
    }

    func cleanup() {
        if let messageCStr { free(messageCStr) }
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
