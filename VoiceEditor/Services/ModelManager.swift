import Foundation
import Dispatch
import FluidAudio
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import HitokuInference
import MLXBackend
import HuggingFace
import Tokenizers

@MainActor
final class ModelManager: ObservableObject {
    @Published var llmProgress: Double = 0
    @Published var sttReady = false
    @Published var sttLoading = false
    @Published var llmReady = false
    @Published var statusMessage = ""
    @Published var selectedModel: ModelOption
    @Published var selectedSTTModel: STTModelOption = {
        // Restore persisted STT choice, falling back to RAM-based default
        if let saved = UserDefaults.standard.string(forKey: "selectedSTTModelID"),
           let match = STTModelRegistry.availableModels.first(where: { $0.id == saved }) {
            return match
        }
        return STTModelRegistry.defaultModel
    }() {
        didSet { UserDefaults.standard.set(selectedSTTModel.id, forKey: "selectedSTTModelID") }
    }
    @Published var autoOffloadEnabled: Bool = true

    private(set) var modelContainer: ModelContainer?
    private(set) var asrModels: AsrModels?
    internal var vadDetector: VoiceActivityDetector?

    /// Unified inference router — callers use this instead of ModelContainer directly.
    let inferenceRouter = InferenceRouter()

    private var idleOffloadTask: Task<Void, Never>?
    private var sttIdleOffloadTask: Task<Void, Never>?
    private static let offloadDelay: TimeInterval = 5 * 60  // 5 minutes for LLM
    private static let sttOffloadDelay: TimeInterval = 2 * 60  // 2 minutes for STT

    /// Unified model cache root: ~/Library/Caches/models/
    /// All model types (LLM, ASR, TTS) download here so there is a single cache to manage.
    nonisolated static var modelsCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models")
    }

    /// Destination for FluidAudio ASR models inside the unified cache.
    /// Mirrors the folder-name convention used by AsrModels.defaultCacheDirectory(for:).
    private var asrCacheDirectory: URL {
        Self.modelsCacheRoot
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
    }

    /// True when the None sentinel is selected (no LLM desired).
    var llmDisabled: Bool { selectedModel.isNone }

    /// Path of the last successfully-loaded LLM — prevents redundant reloads.
    /// Set to nil to force a reload on next `loadModel()`.
    var loadedModelPath: String?

    /// Path of the model that was loaded before the current one.
    /// Used to restore the previous model when the user deletes the active custom model.
    private(set) var previousModelPath: String?

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// GPU cache limit for MLX intermediate computation buffers (not model weights).
    /// 256MB avoids the eviction thrashing that 20MB caused, while staying light
    /// enough for 8GB machines where users run browsers, editors, etc.
    private static let gpuCacheLimit = 256 * 1024 * 1024

    init(model: ModelOption? = nil) {
        if let model {
            self.selectedModel = model
        } else if let savedPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
                  let match = ModelRegistry.availableModels.first(where: { $0.path == savedPath }) {
            self.selectedModel = match
        } else if UserDefaults.standard.string(forKey: "selectedModelPath") != nil {
            // Saved model no longer in the list (removed from bundled defaults) — fall back to smart default
            self.selectedModel = ModelRegistry.smartDefault
        } else {
            self.selectedModel = ModelRegistry.noLLM
        }
        // Restore saved offload preference; default true when key is absent
        autoOffloadEnabled = UserDefaults.standard.object(forKey: "modelAutoOffload")
            .flatMap { $0 as? Bool } ?? false
        startMemoryPressureMonitoring()
    }

    // MARK: - Inactivity Offloading

    /// Reset the 5-minute inactivity countdown. Call after each successful pipeline.
    func keepAlive() {
        guard autoOffloadEnabled else { return }
        idleOffloadTask?.cancel()
        idleOffloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.offloadDelay))
            guard !Task.isCancelled else { return }
            self?.offloadAllModels()
        }
    }

    /// Cancel any pending LLM offload. Call at the start of any pipeline.
    func cancelOffload() {
        idleOffloadTask?.cancel()
        idleOffloadTask = nil
    }

    /// Cancel any pending STT offload. Call before dictation or voice edit that needs STT.
    func cancelSTTOffload() {
        sttIdleOffloadTask?.cancel()
        sttIdleOffloadTask = nil
    }

    /// Reset the independent 2-minute STT inactivity timer.
    /// Call after any pipeline that used STT (dictation, voice edit).
    /// STT (~460 MB) frees independently from the LLM, which has its own 5-minute timer.
    func keepSTTAlive() {
        guard autoOffloadEnabled else { return }
        sttIdleOffloadTask?.cancel()
        sttIdleOffloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.sttOffloadDelay))
            guard !Task.isCancelled else { return }
            self?.offloadSTT()
        }
    }

    /// Release only STT weights from RAM, leaving LLM loaded.
    func offloadSTT() {
        asrModels = nil
        if sttReady { sttReady = false }
    }

    /// Release LLM and STT weights from RAM.
    /// The coordinator clears its `stt` and `llm` vars via `$sttReady`/`$llmReady` Combine sinks.
    func offloadAllModels() {
        if modelContainer != nil || inferenceRouter.isLoaded {
            inferenceRouter.unload()
            modelContainer = nil
            llmReady = false
            Memory.clearCache()
        }
        offloadSTT()
        sttIdleOffloadTask?.cancel()
        sttIdleOffloadTask = nil
    }

    // MARK: - Model Loading

    /// Load a specific model (downloads if needed, then initializes).
    /// If the model is already loaded (matching `loadedModelPath`), returns immediately.
    func loadModel(_ model: ModelOption) async throws {
        // None sentinel: clear LLM state; nothing to load
        guard !model.isNone else {
            inferenceRouter.unload()
            modelContainer = nil
            llmReady = false
            Memory.clearCache()
            loadedModelPath = nil
            statusMessage = ""
            return
        }

        cancelOffload()

        if loadedModelPath == model.path, inferenceRouter.isLoaded {
            return
        }

        Memory.cacheLimit = Self.gpuCacheLimit

        // Unload previous backends — must complete before loading the new model
        // to avoid both models coexisting in memory (OOM risk on 8/16GB machines).
        let router = inferenceRouter
        let keys = router.registeredKeys
        if !keys.isEmpty {
            await Task.detached {
                for key in keys { router.remove(key) }
            }.value
        }
        llmReady = false
        modelContainer = nil
        Memory.clearCache()  // Evict old model's GPU buffers
        if loadedModelPath != nil { previousModelPath = loadedModelPath }
        loadedModelPath = nil
        statusMessage = "Loading \(model.name)..."

        try await loadMLXModel(model)

        self.llmReady = true
        self.loadedModelPath = model.path
        statusMessage = ""
    }

    // MARK: - MLX Loading

    private func loadMLXModel(_ model: ModelOption) async throws {
        // Factory selection — performance-critical gate.
        //
        // Both Qwen 3.5 and Gemma 4 are native-multimodal VLM checkpoints, but
        // `LLMModelFactory` can load them in text-only mode: its weight
        // sanitization strips the vision tower during load, yielding a
        // measurably faster forward pass for prompts without images.
        //
        // - useVLM=true  → VLMModelFactory (required when request has images;
        //                  slower even for text-only prompts).
        // - useVLM=false → LLMModelFactory (text-only path, faster).
        //
        // DO NOT drop the `&& visionEnabled` guard. Users rely on toggling
        // "Allow vision" off in Settings → Advanced to get the fast path.
        // This applies equally to Qwen 3.5 and Gemma 4. See docs/CLAUDE.md
        // "Factory selection is performance-critical" invariant.
        let visionEnabled = UserDefaults.standard.bool(forKey: "visionEnabled")
        let useVLM = model.isVLM && visionEnabled
        let factory: any ModelFactory = useVLM
            ? VLMModelFactory.shared
            : LLMModelFactory.shared
        let container = try await factory.loadContainer(
            from: HubDownloaderBridge(),
            using: HubTokenizerLoaderBridge(),
            configuration: model.configuration
        ) { [weak self] progress in
            Task { @MainActor in
                self?.llmProgress = progress.fractionCompleted
                if progress.totalUnitCount > 100 {
                    let completed = ByteCountFormatter.string(
                        fromByteCount: progress.completedUnitCount, countStyle: .file)
                    let total = ByteCountFormatter.string(
                        fromByteCount: progress.totalUnitCount, countStyle: .file)
                    self?.statusMessage = "Downloading LLM: \(completed) / \(total)"
                }
            }
        }
        self.modelContainer = container

        let backendConfig = BackendConfig(
            disableThinking: model.disableThinking,
            extra: model.family.templateContext.map { ["templateContext": $0] } ?? [:]
        )
        let mlxBackend = MLXInferenceBackend(container: container, config: backendConfig)
        inferenceRouter.register(mlxBackend, as: "mlx")
        inferenceRouter.preferred = "mlx"
    }

    /// Reload only the LLM with the currently selected model.
    /// Called when the user changes the model picker.
    func reloadLLM() async throws {
        try await loadModel(selectedModel)
    }

    /// Reload only the STT with the currently selected model.
    /// Called when the user changes the STT model picker.
    func reloadSTT() async throws {
        sttReady = false
        asrModels = nil

        // None sentinel — no STT to load
        guard !selectedSTTModel.isNone else {
            sttReady = true
            statusMessage = ""
            return
        }

        switch selectedSTTModel.backend {
        case .fluidAudio:
            statusMessage = "Loading STT models..."
            let models = try await AsrModels.downloadAndLoad(to: asrCacheDirectory, version: .v3)
            self.asrModels = models
            self.sttReady = true
        case .whisperKit:
            // Coordinator will handle loading via WhisperKitSTTService init (downloads internally)
            break
        }

        statusMessage = ""
    }

    // MARK: - Memory Pressure

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            Task { @MainActor in
                Memory.clearCache()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }
}

// MARK: - MLX 3.x Bridge (replaces MLXHuggingFace macros)

/// Bridges HuggingFace Hub client to MLXLMCommon.Downloader protocol.
private struct HubDownloaderBridge: MLXLMCommon.Downloader {
    private let hub = HubClient()

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw URLError(.badURL)
        }
        return try await hub.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

/// Bridges swift-transformers AutoTokenizer to MLXLMCommon.TokenizerLoader protocol.
private struct HubTokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Adapts `Tokenizers.Tokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`.
/// The two protocols have slightly different method signatures (e.g. `decode(tokens:)` vs `decode(tokenIds:)`).
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
