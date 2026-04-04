import Foundation

protocol LLMService: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    /// Streams tokens as they are generated. Yields each chunk as it arrives.
    /// The full accumulated text must be post-processed by the caller before pasting.
    func generateStream(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
    func warmup() async throws
}
