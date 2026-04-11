import Foundation
import CoreGraphics
import CoreImage
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import HitokuInference

/// MLX-based inference backend wrapping `ModelContainer` from mlx-swift-lm.
/// Supports text and image modalities.
public final class MLXInferenceBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - State

    private var container: ModelContainer?
    private var config: BackendConfig = .init()

    // MARK: - Init

    /// Create with a pre-loaded container (used when ModelManager handles loading).
    public init(container: ModelContainer, config: BackendConfig = .init()) {
        self.container = container
        self.config = config
    }

    /// Create an empty backend — call `loadModel(at:config:)` before generating.
    public init() {}

    // MARK: - InferenceBackend

    public var supportedModalities: Set<InputModality> { [.text, .image] }

    public var isLoaded: Bool { container != nil }

    public func loadModel(at path: String, config: BackendConfig) async throws {
        self.config = config

        let isVLM = config.extra["isVLM"] as? Bool ?? false
        let factory: any ModelFactory = isVLM
            ? VLMModelFactory.shared
            : LLMModelFactory.shared

        let modelConfig = ModelConfiguration(id: path)
        let loaded = try await factory.loadContainer(configuration: modelConfig)
        self.container = loaded
    }

    public func unload() {
        container = nil
        MLX.Memory.clearCache()
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.modelNotLoaded) }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let lmInput = try await self.prepareInput(request: request, container: container)
                    let parameters = self.makeParameters(request: request)

                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: parameters
                    )

                    var recentChunks: [String] = []
                    recentChunks.reserveCapacity(21)

                    for await generation in stream {
                        if let chunk = generation.chunk {
                            // Repetition detection — bail if the last 20 chunks are degenerate
                            recentChunks.append(chunk)
                            if recentChunks.count > 20 { recentChunks.removeFirst() }
                            if recentChunks.count == 20, Set(recentChunks).count <= 3 { break }

                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Internal helpers

    private func prepareInput(
        request: InferenceRequest,
        container: ModelContainer
    ) async throws -> LMInput {
        let text = request.text ?? ""
        let effectivePrompt = config.disableThinking ? text + " /no_think" : text

        let templateContext = config.extra["templateContext"] as? [String: Any]

        // Build chat messages
        var messages: [Chat.Message] = []
        if let system = request.systemPrompt {
            messages.append(.system(system))
        }

        // Attach images if present
        if let images = request.images, !images.isEmpty {
            let vlmImages = images.map { UserInput.Image.ciImage(CIImage(cgImage: $0)) }
            messages.append(.user(effectivePrompt, images: vlmImages))
        } else {
            messages.append(.user(effectivePrompt))
        }

        let userInput = UserInput(chat: messages, additionalContext: templateContext)
        return try await container.prepare(input: userInput)
    }

    private func makeParameters(request: InferenceRequest) -> GenerateParameters {
        GenerateParameters(
            maxTokens: request.maxTokens,
            kvBits: request.kvBits ?? 4,
            temperature: request.temperature,
            topP: request.topP ?? 0.9,
            repetitionPenalty: request.repetitionPenalty ?? 1.2,
            repetitionContextSize: request.repetitionContextSize ?? 64
        )
    }
}

// MARK: - Errors

public enum InferenceError: LocalizedError {
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded. Call loadModel(at:config:) first."
        }
    }
}
