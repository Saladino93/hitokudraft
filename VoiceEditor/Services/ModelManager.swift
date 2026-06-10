import Foundation
import Dispatch
import FluidAudio
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import HitokuInference
import LiteRTBackend
import MLXBackend
import Observation

@MainActor
@Observable
final class ModelManager {
    var llmProgress: Double = 0
    var sttReady = false
    var sttLoading = false
    var llmReady = false
    var statusMessage = ""
    var selectedModel: ModelOption
    var selectedSTTModel: STTModelOption = {
        // Restore persisted STT choice, falling back to RAM-based default
        if let saved = UserDefaults.standard.string(forKey: "selectedSTTModelID"),
           let match = STTModelRegistry.availableModels.first(where: { $0.id == saved }) {
            return match
        }
        return STTModelRegistry.defaultModel
    }() {
        didSet { UserDefaults.standard.set(selectedSTTModel.id, forKey: "selectedSTTModelID") }
    }
    var autoOffloadEnabled: Bool = true

    @ObservationIgnored private(set) var modelContainer: ModelContainer?
    @ObservationIgnored private(set) var asrModels: AsrModels?
    @ObservationIgnored internal var vadDetector: VoiceActivityDetector?

    /// Unified inference router — callers use this instead of ModelContainer directly.
    let inferenceRouter = InferenceRouter()

    @ObservationIgnored private var idleOffloadTask: Task<Void, Never>?
    @ObservationIgnored private var sttIdleOffloadTask: Task<Void, Never>?
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
    /// Path of the last loaded model. Set to nil to force a reload on next `loadModel()`.
    var loadedModelPath: String?

    /// Path of the model that was loaded before the current one.
    /// Used to restore the previous model when the user deletes the active custom model.
    private(set) var previousModelPath: String?

    // @ObservationIgnored keeps this a plain stored property so the nonisolated
    // deinit can still cancel it (the @Observable macro would make it computed).
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

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
    /// Call after any pipeline that used STT (dictation, voice edit with separate STT).
    /// When Gemma 4 loads STT on-demand for dictation, this lets STT (~460 MB)
    /// free independently from the LLM, which has its own 5-minute timer.
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
            // Run unload off MainActor (LiteRT engineDelete can take seconds)
            // but await completion before proceeding.
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

        switch model.backendType {
        case .mlx:
            try await loadMLXModel(model)
        case .liteRT:
            do {
                try await loadLiteRTModel(model)
            } catch {
                print("[ModelManager] LiteRT loading FAILED: \(error)")
                // Graceful fallback: if LiteRT fails (missing dylibs, bad model, etc.),
                // fall back to the smart MLX default so the app remains functional.
                statusMessage = "LiteRT unavailable, falling back to MLX..."
                let fallback = ModelRegistry.smartDefault
                if !fallback.isNone {
                    try await loadMLXModel(fallback)
                    // Update loadedModelPath to the fallback, not the failed LiteRT model
                    self.llmReady = true
                    self.loadedModelPath = fallback.path
                    statusMessage = ""
                    return
                } else {
                    throw error
                }
            }
        }

        self.llmReady = true
        self.loadedModelPath = model.path
        statusMessage = ""
    }

    // MARK: - MLX Loading (existing path)

    private func loadMLXModel(_ model: ModelOption) async throws {
        let visionEnabled = UserDefaults.standard.bool(forKey: "visionEnabled")
        let useVLM = model.isVLM && visionEnabled
        let factory: any ModelFactory = useVLM
            ? VLMModelFactory.shared
            : LLMModelFactory.shared
        let container = try await factory.loadContainer(
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

    // MARK: - LiteRT Loading

    private func loadLiteRTModel(_ model: ModelOption) async throws {
        guard let filename = model.liteRTFilename else {
            throw LiteRTLoadError.missingFilename
        }

        // Download .litertlm from HuggingFace if not cached
        let cacheDir = Self.modelsCacheRoot.appendingPathComponent(model.path)
        let modelFile = cacheDir.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: modelFile.path) {
            statusMessage = "Downloading \(model.name)..."
            try await downloadLiteRTModel(repo: model.path, filename: filename, to: cacheDir)
        }

        statusMessage = "Loading \(model.name)..."

        // Configure cache dir for LiteRT (speeds up subsequent loads)
        let liteRTCacheDir = cacheDir.appendingPathComponent("cache").path
        try? FileManager.default.createDirectory(atPath: liteRTCacheDir, withIntermediateDirectories: true)

        // Context window scales down for larger models: the KV cache for the full
        // window is allocated when the conversation is created, and an 8192 window on
        // a 12B model is too large to allocate (causes "Failed to create conversation").
        // Smaller models keep the larger window for longer edits.
        let maxNumTokens = model.estimatedMemoryGB >= 8 ? 4096 : 8192

        // Only request a vision backend for models that actually ship a vision encoder.
        // The 12B build is audio + text only; requesting vision fails conversation creation.
        let visionBackend = model.isVLM ? "gpu" : "none"

        let config = BackendConfig(extra: [
            "backend": "gpu",
            "visionBackend": visionBackend,
            "cacheDir": liteRTCacheDir,
            "maxNumTokens": maxNumTokens,
        ])

        let backend = LiteRTInferenceBackend()
        print("[ModelManager] LiteRT runtime available: \(backend.isRuntimeAvailable)")
        guard backend.isRuntimeAvailable else {
            print("[ModelManager] LiteRT runtime NOT available — dylibs missing")
            throw LiteRTLoadError.runtimeNotAvailable
        }

        // LiteRT engine creation is a heavy synchronous C call (~1-2s).
        // Run it off the MainActor to avoid watchdog termination.
        let modelPath = modelFile.path
        print("[ModelManager] Loading LiteRT engine at: \(modelPath)")
        try await Task.detached {
            try await backend.loadModel(at: modelPath, config: config)
        }.value
        print("[ModelManager] LiteRT engine loaded: \(backend.isLoaded)")

        inferenceRouter.register(backend, as: "litert")
        inferenceRouter.preferred = "litert"

        // Unload STT models — Gemma handles audio natively, saves ~460MB
        asrModels = nil
        sttReady = true  // Show green — Gemma IS the STT
        print("[ModelManager] LiteRT registered, STT unloaded (Gemma handles audio)")
    }

    /// Downloads a single file from a HuggingFace repo to the given directory.
    private func downloadLiteRTModel(repo: String, filename: String, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)

        let urlString = "https://huggingface.co/\(repo)/resolve/main/\(filename)"
        guard let url = URL(string: urlString) else {
            throw LiteRTLoadError.invalidURL
        }

        // Stream download with progress reporting
        let delegate = DownloadProgressDelegate { [weak self] fraction in
            Task { @MainActor in
                self?.llmProgress = fraction
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LiteRTLoadError.downloadFailed
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Resolves the `.litertlm` filename inside a LiteRT-LM HuggingFace repo via the
    /// HF API. Prefers the native build over the `-web` (WASM) variant. Returns nil
    /// if the repo can't be read or has no `.litertlm` file (i.e. not a LiteRT repo).
    static func resolveLiteRTFilename(repo: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            return nil
        }
        let files = siblings
            .compactMap { $0["rfilename"] as? String }
            .filter { $0.hasSuffix(".litertlm") }
        // Prefer the native variant; the "-web" build targets WASM/WebGPU in browsers.
        return files.first { !$0.contains("-web") } ?? files.first
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
        case .mlxAudio:
            // Coordinator will handle loading via MLXAudioSTTService init
            break
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

// MARK: - LiteRT Errors

enum LiteRTLoadError: LocalizedError {
    case missingFilename
    case runtimeNotAvailable
    case invalidURL
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .missingFilename: return "LiteRT model has no filename configured."
        case .runtimeNotAvailable: return "LiteRT runtime not available. Ensure dylibs are in app Frameworks/."
        case .invalidURL: return "Invalid HuggingFace download URL."
        case .downloadFailed: return "Failed to download LiteRT model."
        }
    }
}

// MARK: - Download Progress

/// URLSession delegate that reports download progress via a closure.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async download(from:) return value
    }
}
