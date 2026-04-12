import Foundation
import CoreGraphics
import HitokuInference

/// Adapts the app-level `LLMService` protocol to `InferenceRouter`.
///
/// Translates `generate(prompt:maxTokens:)` calls into `InferenceRequest` objects
/// and delegates to the router. This lets every existing caller (`ConversationCoordinator`,
/// `ActionCoordinator`, `DictationPolisher`) keep using `LLMService` unchanged.
final class RoutedLLMService: LLMService, @unchecked Sendable {
    private let router: InferenceRouter
    private let family: any ModelFamily
    private let systemPrompt: String

    init(router: InferenceRouter, family: any ModelFamily, systemPrompt: String) {
        self.router = router
        self.family = family
        self.systemPrompt = systemPrompt
    }

    // MARK: - LLMService

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        try await generate(prompt: prompt, maxTokens: maxTokens, temperature: family.temperature)
    }

    func generate(prompt: String, maxTokens: Int, temperature: Float) async throws -> String {
        let request = makeRequest(prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        return try await router.generateFull(request: request)
    }

    func generateStream(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let request = makeRequest(prompt: prompt, maxTokens: maxTokens, temperature: family.temperature)
        return router.generate(request: request)
    }

    func generateStream(prompt: String, images: [CGImage], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        guard !images.isEmpty else {
            return generateStream(prompt: prompt, maxTokens: maxTokens)
        }
        var request = makeRequest(prompt: prompt, maxTokens: maxTokens, temperature: family.temperature)
        request.images = images
        return router.generate(request: request)
    }

    func generateStream(prompt: String, audio: Data, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        var request = makeRequest(prompt: prompt, maxTokens: maxTokens, temperature: family.temperature)
        request.audio = audio
        return router.generate(request: request)
    }

    /// Combined audio + images for full multimodal input.
    func generateStream(prompt: String, audio: Data, images: [CGImage], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        var request = makeRequest(prompt: prompt, maxTokens: maxTokens, temperature: family.temperature)
        request.audio = audio
        if !images.isEmpty { request.images = images }
        return router.generate(request: request)
    }

    /// Whether the currently resolved (loaded + preferred) backend supports native audio input.
    /// Uses a dummy text request to resolve, then checks that backend's modalities.
    var supportsAudioInput: Bool {
        guard let (_, backend) = router.resolve(for: InferenceRequest(text: "")) else { return false }
        return backend.supportedModalities.contains(.audio)
    }

    func warmup() async throws {
        _ = try await generate(prompt: "Hello", maxTokens: 1)
    }

    // MARK: - Request Builder

    private func makeRequest(prompt: String, maxTokens: Int, temperature: Float) -> InferenceRequest {
        InferenceRequest(
            systemPrompt: systemPrompt,
            text: prompt,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: family.topP,
            repetitionPenalty: family.repetitionPenalty,
            repetitionContextSize: 64,
            kvBits: 4
        )
    }
}
