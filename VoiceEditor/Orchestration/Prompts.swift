import Foundation
import NaturalLanguage

enum Prompts {
    static let systemPrompt = """
        You are a precise, concise text editor and writing assistant. \
        Follow instructions exactly. Output ONLY the requested text — \
        no commentary, no explanations, no preamble.
        """

    static func edit(text: String, instruction: String) -> String {
        let langCode = LanguageDetector.detect(text)
        let langRule = languageRule(for: langCode)

        return """
        You are a precise text editor. The user dictated the INSTRUCTION via voice — \
        it may contain filler words or minor transcription errors. \
        Interpret the intent, not the literal wording.

        Rules:
        - Output ONLY the rewritten text. No explanation, no preamble, no notes.
        - \(langRule)
        - Keep formatting (line breaks, bullet points) unless asked to change it.

        TEXT:
        \(text)

        INSTRUCTION:
        \(instruction)

        REWRITTEN TEXT:
        """
    }

    static func draft(instruction: String) -> String {
        let langCode = LanguageDetector.detect(instruction)
        let langRule = languageRule(for: langCode)

        return """
        \(langRule)
        You are a writing assistant. The user asked you to write something via voice.
        Produce ONLY the requested content — no preamble, no commentary.
        Do NOT repeat or paraphrase the user's request.
        Write directly, as if the text will be pasted into a document.

        Request: \(instruction)

        """
    }

    /// Returns a language rule that names the detected language explicitly.
    /// Uses Apple's NLLanguage to get the localized language name (e.g. "Italian", "Arabic"),
    /// so it works for any language Apple can detect — no hardcoded list.
    private static func languageRule(for langCode: String) -> String {
        guard langCode != "en" else {
            return "Reply in English."
        }

        // Get the language name in English (e.g. "it" → "Italian", "ar" → "Arabic")
        let locale = Locale(identifier: "en")
        let languageName = locale.localizedString(forLanguageCode: langCode)

        // Also get the language name in its own language (e.g. "it" → "italiano")
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

    // MARK: - Voice-clean prompt (for small models that echo labeled fields)

    /// Broader system prompt for small models (e.g. LFM2.5 1.2B) that echo
    /// labeled prompt fields instead of generating content.
    /// Supports editing, drafting, and general tasks — not just voice cleanup.
    static let voiceCleanSystemPrompt = """
        You are a versatile text editor and writing assistant. \
        The user's input was dictated via voice — it may contain filler words, \
        hesitations, or minor transcription errors. Interpret the user's intent. \
        Output ONLY the requested text — no commentary, no explanations, no preamble. \
        Reply in the SAME language as the input.
        """

    /// Draft prompt for small models — avoids labeled fields that small models echo,
    /// but still clearly instructs the model to generate new content.
    static func voiceCleanDraft(instruction: String) -> String {
        """
        The user wants you to write new content. Do not clean up or rewrite their request — \
        produce the actual content they are asking for. Output only the content, nothing else.

        \(instruction)
        """
    }
}
