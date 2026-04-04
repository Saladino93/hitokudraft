import Foundation
import Dispatch
import FluidAudio
import MLX
import MLXLLM
import MLXLMCommon

@MainActor
final class ModelManager: ObservableObject {
    @Published var llmProgress: Double = 0
    @Published var sttReady = false
    @Published var sttLoading = false
    @Published var llmReady = false
    @Published var statusMessage = ""
    @Published var selectedModel: ModelOption
    @Published var selectedSTTModel: STTModelOption = STTModelRegistry.defaultModel
    @Published var autoOffloadEnabled: Bool = true

    private(set) var modelContainer: ModelContainer?
    private(set) var asrModels: AsrModels?
    internal var vadDetector: VoiceActivityDetector?

    private var idleOffloadTask: Task<Void, Never>?
    private static let offloadDelay: TimeInterval = 5 * 60  // 5 minutes, fixed

    /// True when the None sentinel is selected (no LLM desired).
    var llmDisabled: Bool { selectedModel.isNone }

    /// Path of the last successfully-loaded LLM — prevents redundant reloads.
    private(set) var loadedModelPath: String?

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

    /// Cancel any pending offload. Call at the start of any pipeline.
    func cancelOffload() {
        idleOffloadTask?.cancel()
        idleOffloadTask = nil
    }

    /// Release LLM and STT weights from RAM.
    /// The coordinator clears its `stt` and `llm` vars via `$sttReady`/`$llmReady` Combine sinks.
    func offloadAllModels() {
        if modelContainer != nil {
            modelContainer = nil
            llmReady = false
            Memory.clearCache()
        }
        if asrModels != nil {
            asrModels = nil
            sttReady = false
        }
    }

    // MARK: - Model Loading

    /// Load a specific model (downloads if needed, then initializes).
    /// If the model is already loaded (matching `loadedModelPath`), returns immediately.
    func loadModel(_ model: ModelOption) async throws {
        // None sentinel: clear LLM state; nothing to load
        guard !model.isNone else {
            modelContainer = nil
            llmReady = false
            Memory.clearCache()
            loadedModelPath = nil
            statusMessage = ""
            return
        }

        cancelOffload()

        if loadedModelPath == model.path, modelContainer != nil {
            return
        }

        Memory.cacheLimit = Self.gpuCacheLimit

        llmReady = false
        modelContainer = nil
        Memory.clearCache()  // Evict old model's GPU buffers before loading new one
        if loadedModelPath != nil { previousModelPath = loadedModelPath }
        loadedModelPath = nil
        statusMessage = "Loading \(model.name)..."

        let container = try await LLMModelFactory.shared.loadContainer(
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
        self.llmReady = true
        self.loadedModelPath = model.path
        statusMessage = ""
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

        switch selectedSTTModel.backend {
        case .fluidAudio:
            statusMessage = "Loading STT models..."
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            self.asrModels = models
            self.sttReady = true
        case .mlxAudio:
            // Coordinator will handle loading via MLXAudioSTTService init
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
