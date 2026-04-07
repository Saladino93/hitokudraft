import Foundation
import CoreGraphics

protocol LLMService: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    /// Overrides the model family's default temperature for this call.
    /// Used by `DictationPolisher` which needs near-zero temperature to
    /// prevent creative rephrasings during strict transcription cleanup.
    func generate(prompt: String, maxTokens: Int, temperature: Float) async throws -> String
    /// Streams tokens as they are generated. Yields each chunk as it arrives.
    /// The full accumulated text must be post-processed by the caller before pasting.
    func generateStream(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
    /// Streams tokens with optional images for VLM models.
    /// Text-only models ignore the images parameter.
    func generateStream(prompt: String, images: [CGImage], maxTokens: Int) -> AsyncThrowingStream<String, Error>
    func warmup() async throws
}

extension LLMService {
    /// Default: delegates to the temperature-less variant (uses family default).
    /// Services that support temperature override provide their own implementation.
    func generate(prompt: String, maxTokens: Int, temperature: Float) async throws -> String {
        try await generate(prompt: prompt, maxTokens: maxTokens)
    }
    /// Default: text-only models ignore images and delegate to the text-only variant.
    func generateStream(prompt: String, images: [CGImage], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt, maxTokens: maxTokens)
    }
}
