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

    private(set) var modelContainer: ModelContainer?
    private(set) var asrModels: AsrModels?

    init(model: ModelOption = ModelRegistry.smartDefault) {
        self.selectedModel = model
    }

    /// Reload only the LLM with the currently selected model.
    /// Called when the user changes the model picker.
    func reloadLLM() async throws {
        Memory.cacheLimit = 20 * 1024 * 1024

        llmReady = false
        modelContainer = nil
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
        statusMessage = ""
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

        // Load STT models (downloads if needed, then compiles CoreML)
        // Parakeet TDT v3 supports 25 European languages
        statusMessage = "Loading STT models..."
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        self.asrModels = models
        self.sttReady = true

        statusMessage = ""
    }
}
