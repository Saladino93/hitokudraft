import Foundation

/// Encapsulates per-model-family prompting strategy and output post-processing.
/// The coordinator asks the active family for prompts and cleaning — no more
/// scattered flag-checking on ModelOption.
protocol ModelFamily {
    var familyName: String { get }

    /// System prompt for this model family.
    func systemPrompt(screenAware: Bool) -> String

    /// Build the user prompt for an edit operation.
    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String

    /// Build the user prompt for a draft operation.
    func draftPrompt(instruction: String, context: ScreenContext?) -> String

    /// Family-specific post-processing before the universal OutputCleaner runs.
    func postProcess(_ rawOutput: String) -> String

    var temperature: Float { get }
    var topP: Float { get }

    /// Penalty factor for repeating tokens. Liquid docs recommend 1.05 for LFM.
    var repetitionPenalty: Float { get }

    /// Whether to append /no_think to user prompts (Qwen3).
    var disableThinking: Bool { get }

    /// Extra key-value pairs injected into the chat template's Jinja context.
    /// Qwen3.5 uses this to pass `enable_thinking: false`.
    var templateContext: [String: any Sendable]? { get }

    /// Maximum tokens for draft generation.
    var draftMaxTokens: Int { get }

    /// Maximum tokens for edit generation, scaled by input text length.
    func editMaxTokens(for text: String) -> Int
}

// MARK: - Protocol defaults

extension ModelFamily {
    var templateContext: [String: any Sendable]? { nil }
    var draftMaxTokens: Int { Prompts.draftMaxTokens }
    func editMaxTokens(for text: String) -> Int { Prompts.editMaxTokens(for: text) }
}

// MARK: - Default

struct DefaultModelFamily: ModelFamily {
    let familyName = "Default"

    func systemPrompt(screenAware: Bool) -> String {
        screenAware ? Prompts.screenAwareSystemPrompt : Prompts.systemPrompt
    }

    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String {
        Prompts.edit(text: text, instruction: instruction, context: context)
    }

    func draftPrompt(instruction: String, context: ScreenContext?) -> String {
        Prompts.draft(instruction: instruction, context: context)
    }

    func postProcess(_ rawOutput: String) -> String { rawOutput }

    let temperature: Float = 0.6
    let topP: Float = 0.9
    let repetitionPenalty: Float = 1.2
    let disableThinking = false
}

// MARK: - Qwen3

struct Qwen3ModelFamily: ModelFamily {
    let familyName = "Qwen3"

    func systemPrompt(screenAware: Bool) -> String {
        screenAware ? Prompts.screenAwareSystemPrompt : Prompts.systemPrompt
    }

    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String {
        Prompts.edit(text: text, instruction: instruction, context: context)
    }

    func draftPrompt(instruction: String, context: ScreenContext?) -> String {
        Prompts.draft(instruction: instruction, context: context)
    }

    /// Strip any leftover thinking blocks that slipped past the /no_think flag.
    func postProcess(_ rawOutput: String) -> String {
        OutputCleaner.cleanModelOutput(rawOutput)
    }

    let temperature: Float = 0.6
    let topP: Float = 0.9
    let repetitionPenalty: Float = 1.2
    let disableThinking = true
}

// MARK: - Qwen3.5

struct Qwen35ModelFamily: ModelFamily {
    let familyName = "Qwen3.5"

    func systemPrompt(screenAware: Bool) -> String {
        screenAware ? Prompts.screenAwareConciseSystemPrompt : Prompts.conciseSystemPrompt
    }

    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String {
        Prompts.edit(text: text, instruction: instruction, context: context)
    }

    /// Concise draft prompt — no encouragement to write at length.
    func draftPrompt(instruction: String, context: ScreenContext?) -> String {
        Prompts.conciseDraft(instruction: instruction, context: context)
    }

    /// Safety net: strip any thinking blocks that slip through despite
    /// enable_thinking=false (e.g. older chat template versions).
    func postProcess(_ rawOutput: String) -> String {
        OutputCleaner.cleanModelOutput(rawOutput)
    }

    let temperature: Float = 0.5
    let topP: Float = 0.9
    let repetitionPenalty: Float = 1.2
    let disableThinking = false

    /// Tighter token budget — Qwen3.5 is capable enough to say it in fewer tokens.
    let draftMaxTokens: Int = 500

    /// Disable thinking at the Jinja template level — no <think> blocks produced.
    var templateContext: [String: any Sendable]? {
        ["enable_thinking": false]
    }
}

// MARK: - LFM (Liquid)

struct LFMModelFamily: ModelFamily {
    let familyName = "LFM"

    func systemPrompt(screenAware: Bool) -> String {
        screenAware ? Prompts.screenAwareVoiceCleanSystemPrompt : Prompts.voiceCleanSystemPrompt
    }

    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String {
        Prompts.edit(text: text, instruction: instruction, context: context)
    }

    /// LFM echoes labeled fields — use the voice-clean draft prompt that avoids them.
    func draftPrompt(instruction: String, context: ScreenContext?) -> String {
        Prompts.voiceCleanDraft(instruction: instruction, context: context)
    }

    /// Strip echoed instruction patterns that small LFM models produce.
    func postProcess(_ rawOutput: String) -> String {
        var result = rawOutput

        // Strip echoed label lines and common preamble/meta-commentary patterns
        let echoPatterns = [
            #"(?mi)^(?:Request|INSTRUCTION|TEXT|REWRITTEN TEXT)\s*:\s*.*$\n?"#,
            #"(?mi)^Here (?:is|are|'s) (?:the|a|an|your)\s.*:\s*\n?"#,
            #"(?mi)^The user (?:asked|wants|requested|is asking)\s.*$\n?"#,
        ]
        for pattern in echoPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result, options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let temperature: Float = 0.5
    let topP: Float = 0.85
    let repetitionPenalty: Float = 1.1
    let disableThinking = false

    /// LFM needs more headroom once it actually generates content instead of echoing.
    let draftMaxTokens: Int = 1200
}

// MARK: - Granite

struct GraniteModelFamily: ModelFamily {
    let familyName = "Granite"

    func systemPrompt(screenAware: Bool) -> String {
        screenAware ? Prompts.screenAwareSystemPrompt : Prompts.systemPrompt
    }

    func editPrompt(text: String, instruction: String, context: ScreenContext?) -> String {
        Prompts.edit(text: text, instruction: instruction, context: context)
    }

    func draftPrompt(instruction: String, context: ScreenContext?) -> String {
        Prompts.draft(instruction: instruction, context: context)
    }

    func postProcess(_ rawOutput: String) -> String { rawOutput }

    let temperature: Float = 0.6
    let topP: Float = 0.9
    let repetitionPenalty: Float = 1.2
    let disableThinking = false
}
