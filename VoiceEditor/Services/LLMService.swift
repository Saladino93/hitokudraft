import Foundation

protocol LLMService: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func warmup() async throws
}
