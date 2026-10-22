import Foundation
import os
import CoreGraphics
import CoreImage
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import HitokuInference

/// MLX-based inference backend wrapping `ModelContainer` from mlx-swift-lm.
/// Supports text and image modalities.
///
/// Thread safety: all mutable state lives in one `State` value behind an unfair lock.
/// Readers snapshot it once per call, so the class is honestly `Sendable`.
public final class MLXInferenceBackend: InferenceBackend, Sendable {

    // MARK: - State

    private struct State: Sendable {
        var container: ModelContainer?
        var config = BackendConfig()
    }

    private let state: OSAllocatedUnfairLock<State>

    // MARK: - Init

    /// Create with a pre-loaded container (used when ModelManager handles loading).
    public init(container: ModelContainer, config: BackendConfig = .init()) {
        state = OSAllocatedUnfairLock(initialState: State(container: container, config: config))
    }

    /// Create an empty backend — call `loadModel(at:config:)` before generating.
    public init() {
        state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - InferenceBackend

    public var supportedModalities: Set<InputModality> { [.text, .image] }

    public var isLoaded: Bool { state.withLock { $0.container != nil } }

    public func loadModel(at path: String, config: BackendConfig) async throws {
        let isVLM = config.extra["isVLM"] as? Bool ?? false
        let factory: any ModelFactory = isVLM
            ? VLMModelFactory.shared
            : LLMModelFactory.shared

        let modelConfig = ModelConfiguration(id: path)
        let loaded = try await factory.loadContainer(configuration: modelConfig)
        // Publish container and config together, only once the load has succeeded.
        state.withLock {
            $0.container = loaded
            $0.config = config
        }
    }

    public func unload() {
        state.withLock { $0.container = nil }
        MLX.Memory.clearCache()
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        // One snapshot per request: a concurrent load/unload cannot change the container
        // or config mid-generation.
        let snapshot = state.withLock { $0 }
        guard let container = snapshot.container else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.modelNotLoaded) }
        }
        let config = snapshot.config

        return AsyncThrowingStream { continuation in
            // Keep the handle so a consumer that cancels or drops the stream cancels
            // generation. Without this the task keeps MLX decoding to maxTokens/EOS
            // in the background (and holds the container) after the caller has gone.
            let task = Task {
                do {
                    let lmInput = try await self.prepareInput(request: request, container: container, config: config)
                    let parameters = self.makeParameters(request: request)
                    try Task.checkCancellation()

                    // Cancelling this task ends the `for await` below; mlx-swift-lm's
                    // stream termination handler then cancels its own decode task.
                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: parameters
                    )

                    var recentChunks: [String] = []
                    recentChunks.reserveCapacity(21)

                    for await generation in stream {
                        try Task.checkCancellation()
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internal helpers

    private func prepareInput(
        request: InferenceRequest,
        container: ModelContainer,
        config: BackendConfig
    ) async throws -> LMInput {
        let text = request.text ?? ""
        let effectivePrompt = config.disableThinking ? text + " /no_think" : text

        let templateContext = config.extra["templateContext"] as? [String: any Sendable]

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
