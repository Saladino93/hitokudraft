import Foundation
import MLXLMCommon

struct ModelOption: Identifiable, Hashable, Codable {
    let name: String       // display name in UI
    let path: String       // HuggingFace repo ID or absolute local path
    var extraEOSTokens: Set<String> = []
    /// Qwen3-style models default to "thinking" mode, consuming most of the token
    /// budget on a <think> block. Set true to append `/no_think` to prompts.
    var disableThinking: Bool = false
    /// Use a stronger, task-specific system prompt for voice-to-draft.
    /// Small models (LFM2.5 1.2B) echo the labeled `Request:` field rather than
    /// generating content — this flag switches to a bare user turn + richer system prompt.
    var useVoiceCleanPrompt: Bool = false
    /// Short one-line description shown in the settings UI.
    var description: String = ""
    /// Approximate unified-memory footprint when loaded (model weights only).
    /// Used to warn users when the model exceeds 25% of physical RAM.
    var estimatedMemoryGB: Double = 0

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
        case name, path, extraEOSTokens, disableThinking, useVoiceCleanPrompt, description, estimatedMemoryGB
    }

    init(
        name: String,
        path: String,
        extraEOSTokens: Set<String> = [],
        disableThinking: Bool = false,
        useVoiceCleanPrompt: Bool = false,
        description: String = "",
        estimatedMemoryGB: Double = 0
    ) {
        self.name = name
        self.path = path
        self.extraEOSTokens = extraEOSTokens
        self.disableThinking = disableThinking
        self.useVoiceCleanPrompt = useVoiceCleanPrompt
        self.description = description
        self.estimatedMemoryGB = estimatedMemoryGB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        extraEOSTokens = try container.decodeIfPresent(Set<String>.self, forKey: .extraEOSTokens) ?? []
        disableThinking = try container.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? false
        useVoiceCleanPrompt = try container.decodeIfPresent(Bool.self, forKey: .useVoiceCleanPrompt) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        estimatedMemoryGB = try container.decodeIfPresent(Double.self, forKey: .estimatedMemoryGB) ?? 0
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
            description: "Balanced quality, speed, and multilingual writing",
            estimatedMemoryGB: 2.5
        ),
        ModelOption(
            name: "Qwen3 8B 4-bit",
            path: "mlx-community/Qwen3-8B-4bit",
            extraEOSTokens: ["<|im_end|>"],
            disableThinking: true,
            description: "Strongest editing and drafting quality",
            estimatedMemoryGB: 5.0
        ),
        ModelOption(
            name: "Granite 4 1B 4-bit",
            path: "mlx-community/granite-4.0-h-1b-base-4bit",
            description: "Lightweight and reliable for basic rewrites",
            estimatedMemoryGB: 0.8
        ),
        ModelOption(
            name: "Granite 4 1B 8-bit",
            path: "mlx-community/granite-4.0-h-1b-base-8bit",
            description: "Better lightweight rewrites and short drafts",
            estimatedMemoryGB: 1.4
        ),
        ModelOption(
            name: "LFM2.5 1.2B 4-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
            useVoiceCleanPrompt: true,
            description: "Fast, lightweight — best for quick edits",
            estimatedMemoryGB: 1.0
        ),
        ModelOption(
            name: "LFM2.5 1.2B 8-bit",
            path: "mlx-community/LFM2.5-1.2B-Instruct-8bit",
            useVoiceCleanPrompt: true,
            description: "Better quality, still very efficient",
            estimatedMemoryGB: 1.6
        ),
    ]

    /// Selects the best default model for the current device's physical RAM.
    /// Tiers: ≥48 GB → Qwen3 8B | ≥16 GB → Qwen3 4B | <16 GB → LFM2.5 1.2B 4-bit
    static var smartDefault: ModelOption {
        let ramGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824  // UInt64
        let preferred: String
        switch ramGB {
        case 48...:  preferred = "Qwen3-8B"
        case 16...:  preferred = "Qwen3-4B"
        default:     preferred = "LFM2.5"
        }
        return availableModels.first { $0.path.contains(preferred) } ?? availableModels[0]
    }
}
