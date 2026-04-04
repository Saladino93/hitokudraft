import Foundation
import NaturalLanguage

// MARK: - JSON Config Structures

private struct PromptsConfig: Codable {
    let version: Int
    let systemPrompts: SystemPrompts
    let templates: Templates

    struct SystemPrompts: Codable {
        let standard: String
        let screenAware: String
        let voiceClean: String
        let screenAwareVoiceClean: String
        let concise: String
        let screenAwareConcise: String

        enum CodingKeys: String, CodingKey {
            case standard = "default"
            case screenAware, voiceClean, screenAwareVoiceClean, concise, screenAwareConcise
        }
    }

    struct Templates: Codable {
        let edit: String
        let draft: String
        let conciseDraft: String
        let voiceCleanDraft: String
    }
}

// MARK: - Loader

/// Loads from user override (~/Library/Application Support/HitokuDraft/prompts.json),
/// then from the bundled PromptsConfig.json, then falls back to hardcoded strings.
private func loadPromptsConfig() -> PromptsConfig? {
    let decoder = JSONDecoder()

    // 1. User override
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        let userURL = appSupport.appendingPathComponent("HitokuDraft/prompts.json")
        if FileManager.default.fileExists(atPath: userURL.path),
           let data = try? Data(contentsOf: userURL),
           let config = try? decoder.decode(PromptsConfig.self, from: data) {
            return config
        }
    }

    // 2. Bundled JSON
    if let url = Bundle.main.url(forResource: "PromptsConfig", withExtension: "json"),
       let data = try? Data(contentsOf: url),
       let config = try? decoder.decode(PromptsConfig.self, from: data) {
        return config
    }

    return nil
}

// MARK: - Prompts

enum Prompts {

    private static let config: PromptsConfig? = loadPromptsConfig()

    // MARK: System Prompts

    static let systemPrompt: String = config?.systemPrompts.standard ?? """
        You are a precise, concise text editor and writing assistant. \
        Follow instructions exactly. Output ONLY the requested text — \
        no commentary, no explanations, no preamble.
        """

    static let screenAwareSystemPrompt: String = config?.systemPrompts.screenAware ?? """
        You are a precise, concise text editor and writing assistant. \
        Follow instructions exactly. Output ONLY the requested text — \
        no commentary, no explanations, no preamble. \
        You can see what the user has on their screen (app name, window title, visible text). \
        Use this context when relevant to give more accurate results. \
        If the screen context is unrelated to the request, ignore it completely.
        """

    static let voiceCleanSystemPrompt: String = config?.systemPrompts.voiceClean ?? """
        You are a helpful writing assistant. Your job is to produce the content \
        the user asks for — NOT to repeat, echo, or paraphrase their request. \
        The user's input was dictated via voice — it may contain filler words, \
        hesitations, or minor transcription errors. Interpret the user's intent. \
        Output ONLY the requested content — no commentary, no explanations, no preamble. \
        NEVER start your response by restating what the user asked. \
        Reply in the SAME language as the input.
        """

    static let screenAwareVoiceCleanSystemPrompt: String = config?.systemPrompts.screenAwareVoiceClean ?? """
        You are a helpful writing assistant. Your job is to produce the content \
        the user asks for — NOT to repeat, echo, or paraphrase their request. \
        The user's input was dictated via voice — it may contain filler words, \
        hesitations, or minor transcription errors. Interpret the user's intent. \
        Output ONLY the requested content — no commentary, no explanations, no preamble. \
        NEVER start your response by restating what the user asked. \
        Reply in the SAME language as the input. \
        You can see what the user has on their screen. \
        Use this context when relevant. Ignore it when unrelated.
        """

    static let conciseSystemPrompt: String = config?.systemPrompts.concise ?? """
        You are a precise, concise text editor and writing assistant. \
        Follow instructions exactly. Output ONLY the requested text — \
        no commentary, no explanations, no preamble. \
        Be brief. Prefer short, direct responses. Do not elaborate \
        unless the user explicitly asks for detail.
        """

    static let screenAwareConciseSystemPrompt: String = config?.systemPrompts.screenAwareConcise ?? """
        You are a precise, concise text editor and writing assistant. \
        Follow instructions exactly. Output ONLY the requested text — \
        no commentary, no explanations, no preamble. \
        Be brief. Prefer short, direct responses. Do not elaborate \
        unless the user explicitly asks for detail. \
        You can see what the user has on their screen (app name, window title, visible text). \
        Use this context when relevant to give more accurate results. \
        If the screen context is unrelated to the request, ignore it completely.
        """

    // MARK: Template Functions

    static func edit(text: String, instruction: String, context: ScreenContext? = nil) -> String {
        let langCode = LanguageDetector.detect(text)
        let langRule = languageRule(for: langCode)
        let contextBlock: String = context.flatMap { $0.promptBlock }.map { "\n\($0)\n" } ?? ""

        if let template = config?.templates.edit {
            return template
                .replacingOccurrences(of: "{{text}}", with: text)
                .replacingOccurrences(of: "{{instruction}}", with: instruction)
                .replacingOccurrences(of: "{{langRule}}", with: langRule)
                .replacingOccurrences(of: "{{contextBlock}}", with: contextBlock)
        }

        return """
        You are a precise text editor. The user dictated the INSTRUCTION via voice — \
        it may contain filler words or minor transcription errors. \
        Interpret the intent, not the literal wording.

        Rules:
        - Output ONLY the rewritten text. No explanation, no preamble, no notes.
        - \(langRule)
        - Keep formatting (line breaks, bullet points) unless asked to change it.
        \(contextBlock)
        TEXT:
        \(text)

        INSTRUCTION:
        \(instruction)

        REWRITTEN TEXT:
        """
    }

    static func draft(instruction: String, context: ScreenContext? = nil) -> String {
        let contextBlock: String = context.flatMap { $0.promptBlock }.map { "\n\($0)\n" } ?? ""

        if let template = config?.templates.draft {
            return template
                .replacingOccurrences(of: "{{instruction}}", with: instruction)
                .replacingOccurrences(of: "{{contextBlock}}", with: contextBlock)
        }

        return """
        You are a writing assistant. The user asked you to write something via voice.
        Produce ONLY the requested content — no preamble, no commentary.
        Do NOT repeat or paraphrase the user's request.
        Write directly, as if the text will be pasted into a document.
        \(contextBlock)
        Request: \(instruction)

        """
    }

    /// Returns a language rule that names the detected language explicitly.
    private static func languageRule(for langCode: String) -> String {
        guard langCode != "en" else {
            return "Reply in English."
        }
        let locale = Locale(identifier: "en")
        let languageName = locale.localizedString(forLanguageCode: langCode)
        let nativeLocale = Locale(identifier: langCode)
        let nativeName = nativeLocale.localizedString(forLanguageCode: langCode)

        if let languageName, let nativeName {
            return "IMPORTANT: You MUST reply ONLY in \(languageName) (\(nativeName)). Do NOT use English."
        } else if let languageName {
            return "IMPORTANT: You MUST reply ONLY in \(languageName). Do NOT use English."
        } else {
            return "Reply in the SAME LANGUAGE as the user's input. Do NOT use English."
        }
    }

    static func editMaxTokens(for text: String) -> Int {
        max(500, text.split(separator: " ").count * 3)
    }

    static let draftMaxTokens = 800

    // MARK: - Concise Draft (reasoning models, e.g. Qwen3.5)

    static func conciseDraft(instruction: String, context: ScreenContext? = nil) -> String {
        let contextBlock: String = context.flatMap { $0.promptBlock }.map { "\n\($0)\n\n" } ?? ""

        if let template = config?.templates.conciseDraft {
            return template
                .replacingOccurrences(of: "{{instruction}}", with: instruction)
                .replacingOccurrences(of: "{{contextBlock}}", with: contextBlock)
        }

        return """
        Write what the user asks for. Be concise — match the scope of \
        the request. Do not repeat the request. Do not explain. \
        Output only the content itself.
        \(contextBlock)\(instruction)
        """
    }

    // MARK: - Voice-Clean Draft (small models)

    static func voiceCleanDraft(instruction: String, context: ScreenContext? = nil) -> String {
        let contextBlock: String = context.flatMap { $0.promptBlock }.map { "\n\($0)\n\n" } ?? ""

        if let template = config?.templates.voiceCleanDraft {
            return template
                .replacingOccurrences(of: "{{instruction}}", with: instruction)
                .replacingOccurrences(of: "{{contextBlock}}", with: contextBlock)
        }

        return """
        Write the content the user is asking for. Be thorough and detailed — \
        write multiple paragraphs or a complete response, not just one sentence. \
        Do not repeat the user's request. Do not explain what you are doing. \
        Output only the content itself.
        \(contextBlock)\(instruction)
        """
    }
}
