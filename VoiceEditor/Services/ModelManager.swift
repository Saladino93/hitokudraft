import Foundation
import FluidAudio
import MLX
import MLXLLM
import MLXLMCommon

@MainActor
final class ModelManager: ObservableObject {
    @Published var llmProgress: Double = 0
    @Published var sttReady = false
    @Published var llmReady = false
    @Published var statusMessage = ""
    @Published var selectedModel: ModelOption
    @Published var selectedSTTModel: STTModelOption = STTModelRegistry.defaultModel

    private(set) var modelContainer: ModelContainer?
    private(set) var asrModels: AsrModels?

    /// Path of the last successfully-loaded LLM — prevents redundant reloads.
    private(set) var loadedModelPath: String?

    init(model: ModelOption? = nil) {
        if let model {
            self.selectedModel = model
        } else if let savedPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
                  let match = ModelRegistry.availableModels.first(where: { $0.path == savedPath }) {
            self.selectedModel = match
        } else {
            self.selectedModel = ModelRegistry.smartDefault
        }
    }

    /// Load a specific model (downloads if needed, then initializes).
    /// If the model is already loaded (matching `loadedModelPath`), returns immediately.
    func loadModel(_ model: ModelOption) async throws {
        if loadedModelPath == model.path, modelContainer != nil {
            return
        }

        Memory.cacheLimit = 20 * 1024 * 1024

        llmReady = false
        modelContainer = nil
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

    func loadAll() async throws {
        // Set GPU cache limit before loading models
        Memory.cacheLimit = 20 * 1024 * 1024

        // Load LLM (downloads if not cached, then initializes)
        statusMessage = "Loading \(selectedModel.name)..."
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: selectedModel.configuration
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
        self.loadedModelPath = selectedModel.path

        // Load STT models — branch on selected backend
        switch selectedSTTModel.backend {
        case .fluidAudio:
            // Parakeet TDT v3 supports 25 European languages
            statusMessage = "Loading STT models..."
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            self.asrModels = models
            self.sttReady = true
        case .mlxAudio:
            // MLXAudioSTTService loads weights during init, driven by the coordinator.
            break
        }

        statusMessage = ""
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

}
