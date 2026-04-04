import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class MLXLLMService: LLMService, @unchecked Sendable {
    private let modelContainer: ModelContainer
    private let family: any ModelFamily
    private let systemPrompt: String

    init(container: ModelContainer, family: any ModelFamily = DefaultModelFamily(), systemPrompt: String = Prompts.systemPrompt) {
        self.modelContainer = container
        self.family = family
        self.systemPrompt = systemPrompt
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        let effectivePrompt = family.disableThinking ? prompt + " /no_think" : prompt
        let userInput = UserInput(chat: [
            .system(self.systemPrompt),
            .user(effectivePrompt)
        ], additionalContext: family.templateContext)
        let lmInput = try await modelContainer.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: family.temperature,
            topP: family.topP,
            repetitionPenalty: family.repetitionPenalty,
            repetitionContextSize: 64
        )

        let stream = try await modelContainer.generate(
            input: lmInput,
            parameters: parameters
        )

        var result = ""
        result.reserveCapacity(8192)
        var recentChunks: [String] = []
        recentChunks.reserveCapacity(21)

        for await generation in stream {
            if let chunk = generation.chunk {
                result.append(chunk)

                // Early stopping: detect degenerate repetition loops
                recentChunks.append(chunk)
                if recentChunks.count > 20 {
                    recentChunks.removeFirst()
                }
                if recentChunks.count == 20 {
                    let unique = Set(recentChunks)
                    if unique.count <= 3 {
                        break
                    }
                }
            }
        }
        return result
    }

    func generateStream(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    let effectivePrompt = family.disableThinking ? prompt + " /no_think" : prompt
                    let userInput = UserInput(chat: [
                        .system(systemPrompt),
                        .user(effectivePrompt)
                    ], additionalContext: family.templateContext)
                    let lmInput = try await modelContainer.prepare(input: userInput)
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: family.temperature,
                        topP: family.topP,
                        repetitionPenalty: family.repetitionPenalty,
                        repetitionContextSize: 64
                    )
                    let stream = try await modelContainer.generate(
                        input: lmInput,
                        parameters: parameters
                    )
                    var recentChunks: [String] = []
                    recentChunks.reserveCapacity(21)
                    for await generation in stream {
                        if let chunk = generation.chunk {
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

    func warmup() async throws {
        _ = try await generate(prompt: "Hello", maxTokens: 1)
    }
}
