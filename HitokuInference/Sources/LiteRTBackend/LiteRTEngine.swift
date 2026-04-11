import Foundation
import CLiteRTEngine

/// Dynamically loaded LiteRT-LM engine functions.
///
/// Uses `dlopen` to load `liblitert_lm_engine.dylib` from the app bundle's
/// Frameworks/ directory at runtime. This avoids compile-time linker path issues
/// and lets the app run even when LiteRT dylibs aren't present (graceful degradation).
final class LiteRTEngineLoader: @unchecked Sendable {

    static let shared = LiteRTEngineLoader()

    private var handle: UnsafeMutableRawPointer?
    private var didAttemptLoad = false

    /// Whether the engine dylib was successfully loaded.
    var isAvailable: Bool {
        ensureLoaded()
        return handle != nil
    }

    private init() {
        // Do NOT load eagerly — defer until first access to avoid crashing
        // the app at launch when dylibs have issues.
    }

    /// Attempt to load the dylib exactly once.
    private func ensureLoaded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        var paths = [String]()
        if let frameworksPath = Bundle.main.privateFrameworksPath {
            paths.append("\(frameworksPath)/liblitert_lm_engine.dylib")
        }
        paths.append("@rpath/liblitert_lm_engine.dylib")
        paths.append("liblitert_lm_engine.dylib")

        for path in paths {
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                handle = h
                return
            }
        }
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    /// Resolve a C function symbol.
    func symbol<T>(_ name: String) -> T? {
        guard let handle else { return nil }
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }
}

// MARK: - Function typedefs matching engine.h

// Engine settings
typealias FnEngineSettingsCreate = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> OpaquePointer?

typealias FnEngineSettingsDelete = @convention(c) (OpaquePointer?) -> Void
typealias FnEngineSettingsSetCacheDir = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
typealias FnEngineSettingsSetMaxNumTokens = @convention(c) (OpaquePointer?, Int32) -> Void

// Engine
typealias FnEngineCreate = @convention(c) (OpaquePointer?) -> OpaquePointer?
typealias FnEngineDelete = @convention(c) (OpaquePointer?) -> Void

// Session config
typealias FnSessionConfigCreate = @convention(c) () -> OpaquePointer?
typealias FnSessionConfigDelete = @convention(c) (OpaquePointer?) -> Void
typealias FnSessionConfigSetMaxOutputTokens = @convention(c) (OpaquePointer?, Int32) -> Void
typealias FnSessionConfigSetSamplerParams = @convention(c) (OpaquePointer?, UnsafePointer<LiteRtLmSamplerParams>?) -> Void

// Conversation config
typealias FnConversationConfigCreate = @convention(c) (
    OpaquePointer?, OpaquePointer?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, Bool
) -> OpaquePointer?
typealias FnConversationConfigDelete = @convention(c) (OpaquePointer?) -> Void

// Conversation
typealias FnConversationCreate = @convention(c) (OpaquePointer?, OpaquePointer?) -> OpaquePointer?
typealias FnConversationDelete = @convention(c) (OpaquePointer?) -> Void
typealias FnConversationSendMessageStream = @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    LiteRtLmStreamCallback?, UnsafeMutableRawPointer?
) -> Int32
typealias FnConversationCancelProcess = @convention(c) (OpaquePointer?) -> Void

// Logging
typealias FnSetMinLogLevel = @convention(c) (Int32) -> Void

// MARK: - Resolved function table

/// Lazily-resolved function pointers for the LiteRT C API.
struct LiteRTFunctions {
    let engineSettingsCreate: FnEngineSettingsCreate
    let engineSettingsDelete: FnEngineSettingsDelete
    let engineSettingsSetCacheDir: FnEngineSettingsSetCacheDir
    let engineSettingsSetMaxNumTokens: FnEngineSettingsSetMaxNumTokens
    let engineCreate: FnEngineCreate
    let engineDelete: FnEngineDelete
    let sessionConfigCreate: FnSessionConfigCreate
    let sessionConfigDelete: FnSessionConfigDelete
    let sessionConfigSetMaxOutputTokens: FnSessionConfigSetMaxOutputTokens
    let sessionConfigSetSamplerParams: FnSessionConfigSetSamplerParams
    let conversationConfigCreate: FnConversationConfigCreate
    let conversationConfigDelete: FnConversationConfigDelete
    let conversationCreate: FnConversationCreate
    let conversationDelete: FnConversationDelete
    let conversationSendMessageStream: FnConversationSendMessageStream
    let conversationCancelProcess: FnConversationCancelProcess
    let setMinLogLevel: FnSetMinLogLevel

    /// Resolve all required functions. Returns nil if any are missing.
    static func resolve() -> LiteRTFunctions? {
        let loader = LiteRTEngineLoader.shared
        guard loader.isAvailable else { return nil }

        guard
            let f1: FnEngineSettingsCreate = loader.symbol("litert_lm_engine_settings_create"),
            let f2: FnEngineSettingsDelete = loader.symbol("litert_lm_engine_settings_delete"),
            let f3: FnEngineSettingsSetCacheDir = loader.symbol("litert_lm_engine_settings_set_cache_dir"),
            let f4: FnEngineSettingsSetMaxNumTokens = loader.symbol("litert_lm_engine_settings_set_max_num_tokens"),
            let f5: FnEngineCreate = loader.symbol("litert_lm_engine_create"),
            let f6: FnEngineDelete = loader.symbol("litert_lm_engine_delete"),
            let f7: FnSessionConfigCreate = loader.symbol("litert_lm_session_config_create"),
            let f8: FnSessionConfigDelete = loader.symbol("litert_lm_session_config_delete"),
            let f9: FnSessionConfigSetMaxOutputTokens = loader.symbol("litert_lm_session_config_set_max_output_tokens"),
            let f10: FnSessionConfigSetSamplerParams = loader.symbol("litert_lm_session_config_set_sampler_params"),
            let f11: FnConversationConfigCreate = loader.symbol("litert_lm_conversation_config_create"),
            let f12: FnConversationConfigDelete = loader.symbol("litert_lm_conversation_config_delete"),
            let f13: FnConversationCreate = loader.symbol("litert_lm_conversation_create"),
            let f14: FnConversationDelete = loader.symbol("litert_lm_conversation_delete"),
            let f15: FnConversationSendMessageStream = loader.symbol("litert_lm_conversation_send_message_stream"),
            let f16: FnConversationCancelProcess = loader.symbol("litert_lm_conversation_cancel_process"),
            let f17: FnSetMinLogLevel = loader.symbol("litert_lm_set_min_log_level")
        else {
            return nil
        }

        return LiteRTFunctions(
            engineSettingsCreate: f1,
            engineSettingsDelete: f2,
            engineSettingsSetCacheDir: f3,
            engineSettingsSetMaxNumTokens: f4,
            engineCreate: f5,
            engineDelete: f6,
            sessionConfigCreate: f7,
            sessionConfigDelete: f8,
            sessionConfigSetMaxOutputTokens: f9,
            sessionConfigSetSamplerParams: f10,
            conversationConfigCreate: f11,
            conversationConfigDelete: f12,
            conversationCreate: f13,
            conversationDelete: f14,
            conversationSendMessageStream: f15,
            conversationCancelProcess: f16,
            setMinLogLevel: f17
        )
    }
}
