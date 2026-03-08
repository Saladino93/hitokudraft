import Foundation
import MLXLMCommon

struct ModelOption: Identifiable, Hashable, Codable {
    let name: String       // display name in UI
    let path: String       // HuggingFace repo ID or absolute local path
    var extraEOSTokens: Set<String> = []

    var id: String { path }

    var isLocal: Bool { path.hasPrefix("/") }

    var configuration: ModelConfiguration {
        if isLocal {
            return ModelConfiguration(
                directory: URL(fileURLWithPath: path),
                extraEOSTokens: extraEOSTokens
            )
        } else {
            return ModelConfiguration(
                id: path,
                extraEOSTokens: extraEOSTokens
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, path, extraEOSTokens
    }

    init(name: String, path: String, extraEOSTokens: Set<String> = []) {
        self.name = name
        self.path = path
        self.extraEOSTokens = extraEOSTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        extraEOSTokens = try container.decodeIfPresent(Set<String>.self, forKey: .extraEOSTokens) ?? []
    }
}

enum ModelRegistry {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voiceeditor")
    private static let configFile = configDirectory.appendingPathComponent("models.json")

    static private(set) var availableModels: [ModelOption] = loadModels()

    static var defaultModel: ModelOption { availableModels[0] }

    /// Reload models from disk (e.g. after config change + app restart).
    static func reload() {
        availableModels = loadModels()
    }

    private static func loadModels() -> [ModelOption] {
        if FileManager.default.fileExists(atPath: configFile.path) {
            do {
                let data = try Data(contentsOf: configFile)
                let models = try JSONDecoder().decode([ModelOption].self, from: data)
                if !models.isEmpty { return models }
            } catch {
                print("Warning: Failed to parse \(configFile.path): \(error). Using defaults.")
            }
        }
        return bundledDefaults
    }

    private static let bundledDefaults: [ModelOption] = [
        ModelOption(
            name: "Qwen3 4B 4-bit",
            path: "mlx-community/Qwen3-4B-4bit",
            extraEOSTokens: ["<|im_end|>"]
        ),
        ModelOption(
            name: "Qwen3 8B 4-bit",
            path: "mlx-community/Qwen3-8B-4bit",
            extraEOSTokens: ["<|im_end|>"]
        ),
        ModelOption(
            name: "Gemma 3 4B 4-bit",
            path: "mlx-community/gemma-3-text-4b-it-4bit",
            extraEOSTokens: ["<end_of_turn>"]
        ),
        ModelOption(
            name: "Qwen3 1.7B 4-bit",
            path: "mlx-community/Qwen3-1.7B-4bit",
            extraEOSTokens: ["<|im_end|>"]
        ),
        ModelOption(
            name: "Gemma 3 1B 4-bit",
            path: "mlx-community/gemma-3-1b-it-4bit",
            extraEOSTokens: ["<end_of_turn>"]
        ),
        ModelOption(
            name: "Gemma 3 1B 8-bit",
            path: "mlx-community/gemma-3-1b-it-8bit",
            extraEOSTokens: ["<end_of_turn>"]
        ),
        ModelOption(
            name: "Granite 4 1B 4-bit",
            path: "mlx-community/granite-4.0-h-1b-base-4bit"
        ),
        ModelOption(
            name: "Granite 4 1B 8-bit",
            path: "mlx-community/granite-4.0-h-1b-base-8bit"
        ),
        ModelOption(
            name: "LFM2.5 1.2B 4-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-4bit"
        ),
        ModelOption(
            name: "LFM2.5 1.2B 8-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-8bit"
        ),
    ]
}
