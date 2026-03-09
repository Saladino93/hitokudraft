import Foundation
import MLXLMCommon

struct ModelOption: Identifiable, Hashable, Codable {
    let name: String       // display name in UI
    let path: String       // HuggingFace repo ID or absolute local path
    var extraEOSTokens: Set<String> = []
    /// Qwen3-style models default to "thinking" mode, consuming most of the token
    /// budget on a <think> block. Set true to append `/no_think` to prompts.
    var disableThinking: Bool = false
    /// Short one-line description shown in the settings UI.
    var description: String = ""

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
        case name, path, extraEOSTokens, disableThinking, description
    }

    init(
        name: String,
        path: String,
        extraEOSTokens: Set<String> = [],
        disableThinking: Bool = false,
        description: String = ""
    ) {
        self.name = name
        self.path = path
        self.extraEOSTokens = extraEOSTokens
        self.disableThinking = disableThinking
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        extraEOSTokens = try container.decodeIfPresent(Set<String>.self, forKey: .extraEOSTokens) ?? []
        disableThinking = try container.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

enum ModelRegistry {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/hitokudraft")
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
            extraEOSTokens: ["<|im_end|>"],
            disableThinking: true,
            description: "Balanced quality, speed, and multilingual writing"
        ),
        ModelOption(
            name: "Qwen3 8B 4-bit",
            path: "mlx-community/Qwen3-8B-4bit",
            extraEOSTokens: ["<|im_end|>"],
            disableThinking: true,
            description: "Strongest editing and drafting quality"
        ),
        ModelOption(
            name: "Granite 4 1B 4-bit",
            path: "mlx-community/granite-4.0-h-1b-base-4bit",
            description: "Lightweight and reliable for basic rewrites"
        ),
        ModelOption(
            name: "Granite 4 1B 8-bit",
            path: "mlx-community/granite-4.0-h-1b-base-8bit",
            description: "Better lightweight rewrites and short drafts"
        ),
        ModelOption(
            name: "LFM2.5 1.2B 4-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
            description: "Fast, lightweight — best for quick edits"
        ),
        ModelOption(
            name: "LFM2.5 1.2B 8-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-8bit",
            description: "Better quality, still very efficient"
        ),
    ]
}
