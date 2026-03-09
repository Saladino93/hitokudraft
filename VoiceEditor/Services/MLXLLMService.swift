import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class MLXLLMService: LLMService, Sendable {
    private let modelContainer: ModelContainer
    private let disableThinking: Bool

    init(container: ModelContainer, disableThinking: Bool = false) {
        self.modelContainer = container
        self.disableThinking = disableThinking
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        let effectivePrompt = disableThinking ? prompt + " /no_think" : prompt
        let userInput = UserInput(prompt: .chat([.user(effectivePrompt)]))
        let lmInput = try await modelContainer.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.6,
            topP: 0.9,
            repetitionPenalty: 1.2,
            repetitionContextSize: 64
        )

        let stream = try await modelContainer.generate(
            input: lmInput,
            parameters: parameters
        )

        var result = ""
        var recentChunks: [String] = []

        for await generation in stream {
            if let chunk = generation.chunk {
                result += chunk

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

    func warmup() async throws {
        _ = try await generate(prompt: "Hello", maxTokens: 1)
    }
}
