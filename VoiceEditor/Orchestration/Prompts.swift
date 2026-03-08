import Foundation
import NaturalLanguage

enum Prompts {
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
        Write exactly what the user asks for. Output ONLY the final text. No commentary.

        User: \(instruction)

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
}
