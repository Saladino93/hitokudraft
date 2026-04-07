import Foundation

/// Unified interface for local inference backends.
///
/// Each backend (MLX, LiteRT, CoreML, …) conforms to this protocol.
/// Callers depend only on the protocol — never on a concrete backend type.
public protocol InferenceBackend: Sendable {
    /// Which input kinds this backend can process.
    var supportedModalities: Set<InputModality> { get }

    /// Whether a model is currently loaded and ready for inference.
    var isLoaded: Bool { get }

    /// Load a model from a local path with backend-specific configuration.
    func loadModel(at path: String, config: BackendConfig) async throws

    /// Unload the current model and free resources.
    func unload()

    /// Stream generated tokens for the given request.
    func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error>
}

// MARK: - Convenience

extension InferenceBackend {
    /// Collect the full streamed output into a single string.
    public func generateFull(request: InferenceRequest) async throws -> String {
        var result = ""
        result.reserveCapacity(4096)
        for try await chunk in generate(request: request) {
            result.append(chunk)
        }
        return result
    }
}
