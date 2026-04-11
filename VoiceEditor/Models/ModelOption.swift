import Foundation
import MLXLMCommon

/// Which inference framework loads and runs this model.
enum InferenceBackendType: String, Codable, Hashable {
    case mlx       // MLX via ModelContainer (existing)
    case liteRT    // LiteRT-LM via C API + dylibs
}

struct ModelOption: Identifiable, Hashable, Codable {
    let name: String       // display name in UI
    let path: String       // HuggingFace repo ID or absolute local path
    var backendType: InferenceBackendType = .mlx
    /// HuggingFace filename to download for LiteRT models (e.g. "gemma-4-E2B-it.litertlm").
    var liteRTFilename: String?
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

    /// Maximum character budget for document context (PDF pages, Pages/Word body) injected
    /// into the LLM prompt. Scales with model size so small models are not overloaded.
    /// 0 for the None sentinel (no LLM) — document extraction is skipped entirely.
    var documentContextBudget: Int {
        switch estimatedMemoryGB {
        case 0:       return 0      // None sentinel — no LLM
        case ..<2:    return 600    // LFM 1.2B, very tight context
        case ..<5:    return 1500   // Qwen3.5 4B, Granite 4 Micro
        default:      return 2500   // Qwen3.5 9B and above
        }
    }

    var id: String { path }

    var isLocal: Bool { path.hasPrefix("/") }

    /// Returns true when this is the "None — STT only" sentinel (no LLM loaded).
    var isNone: Bool { path == "__none__" }

    /// True when the model should be loaded via VLMModelFactory (vision path).
    /// Qwen3.5 is natively multimodal — all sizes are VLMs. Other families use
    /// explicit "-VL" or "-vlm" suffix convention.
    var isVLM: Bool {
        let lower = path.lowercased()
        if lower.contains("qwen3.5") { return true }
        // Gemma 4 via LiteRT is natively multimodal (audio + vision + text)
        if lower.contains("gemma-4") || lower.contains("gemma4") { return true }
        return lower.contains("-vl-") || lower.contains("-vlm")
            || lower.hasSuffix("-vl")
    }

    /// Resolves the model family strategy by inspecting the model path.
    var family: any ModelFamily {
        let lower = path.lowercased()
        if lower.contains("qwen3.5") { return Qwen35ModelFamily() }
        if lower.contains("qwen3") { return Qwen3ModelFamily() }
        if lower.contains("lfm") { return LFMModelFamily() }
        if lower.contains("granite") { return GraniteModelFamily() }
        if lower.contains("gemma-4") || lower.contains("gemma4") { return Gemma4ModelFamily() }
        return DefaultModelFamily()
    }

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
        case name, path, backendType, liteRTFilename, extraEOSTokens, disableThinking, useVoiceCleanPrompt, description, estimatedMemoryGB
    }

    init(
        name: String,
        path: String,
        backendType: InferenceBackendType = .mlx,
        liteRTFilename: String? = nil,
        extraEOSTokens: Set<String> = [],
        disableThinking: Bool = false,
        useVoiceCleanPrompt: Bool = false,
        description: String = "",
        estimatedMemoryGB: Double = 0
    ) {
        self.name = name
        self.path = path
        self.backendType = backendType
        self.liteRTFilename = liteRTFilename
        self.extraEOSTokens = extraEOSTokens
        self.disableThinking = disableThinking
        self.useVoiceCleanPrompt = useVoiceCleanPrompt
        self.description = description
        self.estimatedMemoryGB = estimatedMemoryGB
    }

    /// Auto-configures model flags by inspecting the HuggingFace path.
    /// Qwen3 models get `disableThinking` + extra EOS; LFM models get voice-clean prompt.
    static func autoConfigured(name: String, path: String) -> ModelOption {
        let lower = path.lowercased()
        if lower.contains("qwen3.5") {
            return ModelOption(
                name: name, path: path,
                extraEOSTokens: ["<|im_end|>"]
            )
        } else if lower.contains("qwen3") {
            return ModelOption(
                name: name, path: path,
                extraEOSTokens: ["<|im_end|>"],
                disableThinking: true
            )
        } else if lower.contains("lfm") {
            return ModelOption(
                name: name, path: path,
                useVoiceCleanPrompt: true
            )
        // } else if lower.contains("gemma-4") {  // pending mlx-swift support
        //     return ModelOption(name: name, path: path, extraEOSTokens: ["<end_of_turn>"])
        } else {
            return ModelOption(name: name, path: path)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        backendType = try container.decodeIfPresent(InferenceBackendType.self, forKey: .backendType) ?? .mlx
        liteRTFilename = try container.decodeIfPresent(String.self, forKey: .liteRTFilename)
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

    /// Sentinel: no LLM loaded. Voice edit pastes raw STT transcript; grammar fix silently no-ops.
    static let noLLM = ModelOption(
        name: "None (STT only)",
        path: "__none__",
        description: "model.none_description",
        estimatedMemoryGB: 0
    )

    static private(set) var availableModels: [ModelOption] = {
        var models = loadModels()
        models.insert(noLLM, at: 0)
        return models
    }()

    static var defaultModel: ModelOption { availableModels[0] }

    /// Reload models from disk (e.g. after config change + app restart).
    static func reload() {
        var models = loadModels()
        models.insert(noLLM, at: 0)
        availableModels = models
    }

    private static func loadModels() -> [ModelOption] {
        if FileManager.default.fileExists(atPath: configFile.path) {
            do {
                let data = try Data(contentsOf: configFile)
                var models = try JSONDecoder().decode([ModelOption].self, from: data)
                if !models.isEmpty {
                    // Merge any new bundled models that were added in app updates
                    let persistedPaths = Set(models.map(\.path))
                    for bundled in bundledDefaults where !persistedPaths.contains(bundled.path) {
                        if bundled.estimatedMemoryGB > 0,
                           let idx = models.lastIndex(where: { $0.estimatedMemoryGB > 0 && $0.estimatedMemoryGB <= bundled.estimatedMemoryGB }) {
                            models.insert(bundled, at: idx + 1)
                        } else {
                            models.append(bundled)
                        }
                    }
                    // Backfill unknown sizes from disk
                    for i in models.indices where models[i].estimatedMemoryGB == 0 {
                        let measured = measureModelOnDisk(models[i])
                        if measured > 0 { models[i].estimatedMemoryGB = measured }
                    }
                    return models
                }
            } catch {
                print("Warning: Failed to parse \(configFile.path): \(error). Using defaults.")
            }
        }
        return bundledDefaults
    }

    private static let bundledDefaults: [ModelOption] = [
        ModelOption(
            name: "Qwen3.5 0.8B 4-bit",
            path: "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            extraEOSTokens: ["<|im_end|>"],
            description: "Tiny multilingual model (fast, lower quality)",
            estimatedMemoryGB: 0.5
        ),
        ModelOption(
            name: "Qwen3.5 4B 4-bit",
            path: "mlx-community/Qwen3.5-4B-4bit",
            extraEOSTokens: ["<|im_end|>"],
            description: "Smart multilingual editing (excellent for its size)",
            estimatedMemoryGB: 2.5
        ),
        ModelOption(
            name: "Gemma 4 E2B",
            path: "litert-community/gemma-4-E2B-it-litert-lm",
            backendType: .liteRT,
            liteRTFilename: "gemma-4-E2B-it.litertlm",
            description: "Native audio + vision (fastest end-to-end)",
            estimatedMemoryGB: 2.6
        ),
        ModelOption(
            name: "Gemma 4 E4B",
            path: "litert-community/gemma-4-E4B-it-litert-lm",
            backendType: .liteRT,
            liteRTFilename: "gemma-4-E4B-it.litertlm",
            description: "Larger multimodal model, higher quality (needs 4+ GB RAM)",
            estimatedMemoryGB: 3.7
        ),
        ModelOption(
            name: "Qwen3.5 9B 4-bit",
            path: "mlx-community/Qwen3.5-9B-4bit",
            extraEOSTokens: ["<|im_end|>"],
            description: "Best overall quality (top multilingual and reasoning)",
            estimatedMemoryGB: 6.5
        ),
    ]

    /// Selects the best default model for the current device's RAM.
    /// ≥16 GB → Qwen3.5 9B | ≥8 GB → Gemma 4 E2B | <8 GB → Qwen3.5 0.8B
    static var smartDefault: ModelOption {
        let ramGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824  // UInt64

        let preferred: String
        switch ramGB {
        case 16...:
            preferred = "Qwen3.5-9B"
        case 8...:
            preferred = "gemma-4-E2B"
        default:
            preferred = "Qwen3.5-0.8B"
        }
        return availableModels.first { $0.path.contains(preferred) }
            ?? availableModels.first { !$0.isNone }
            ?? availableModels[0]
    }

    /// Scans the model's cache directory for .safetensors files and returns
    /// total size in GB, or 0 if the directory doesn't exist yet.
    static func measureModelOnDisk(_ model: ModelOption) -> Double {
        let fm = FileManager.default
        let dir: URL
        if model.isLocal {
            dir = URL(fileURLWithPath: model.path)
        } else {
            guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
            dir = caches.appendingPathComponent("models").appendingPathComponent(model.path)
        }
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        let totalBytes = contents
            .filter { $0.pathExtension == "safetensors" }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        return totalBytes > 0 ? Double(totalBytes) / 1_073_741_824 : 0
    }

    // MARK: - Custom Model Management

    /// Returns true if the model is one of the bundled defaults or the None sentinel (non-removable).
    static func isBundled(_ model: ModelOption) -> Bool {
        model.isNone || bundledDefaults.contains { $0.path == model.path }
    }

    /// Adds a custom model to the registry. Returns false if a model with the same path already exists.
    /// Models with a known memory size are inserted in ascending memory order.
    @discardableResult
    static func addModel(_ model: ModelOption) -> Bool {
        guard !availableModels.contains(where: { $0.path == model.path }) else { return false }
        // Insert in memory-ascending order (after the last model with smaller/equal memory)
        if model.estimatedMemoryGB > 0,
           let insertIndex = availableModels.lastIndex(where: { $0.estimatedMemoryGB <= model.estimatedMemoryGB }) {
            availableModels.insert(model, at: insertIndex + 1)
        } else {
            availableModels.append(model)
        }
        save()
        return true
    }

    /// Removes a user-added model from the registry and deletes its cached weights from disk.
    /// Local models (absolute paths) are unregistered but their files are not touched.
    /// Returns false if the model is bundled.
    @discardableResult
    static func removeModel(_ model: ModelOption) -> Bool {
        guard !isBundled(model) else { return false }
        availableModels.removeAll { $0.path == model.path }
        save()
        // Delete cached weights for HuggingFace models (not local paths)
        if !model.isLocal {
            deleteCachedWeights(for: model)
        }
        return true
    }

    /// Deletes the cached model directory under ~/Library/Caches/models/<path>.
    private static func deleteCachedWeights(for model: ModelOption) {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("models").appendingPathComponent(model.path)
        guard fm.fileExists(atPath: dir.path) else { return }
        do {
            try fm.removeItem(at: dir)
        } catch {
            print("Warning: Failed to delete model cache at \(dir.path): \(error)")
        }
    }

    private static func save() {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            // Never persist the None sentinel — it's always prepended at runtime
            let data = try JSONEncoder().encode(availableModels.filter { !$0.isNone })
            try data.write(to: configFile, options: .atomic)
        } catch {
            print("Warning: Failed to save models to \(configFile.path): \(error)")
        }
    }
}
