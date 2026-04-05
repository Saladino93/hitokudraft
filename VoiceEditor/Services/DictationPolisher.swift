import Foundation

/// Lightweight LLM pass that cleans up raw dictation transcripts:
/// removes filler words (um, uh, like, you know) and adds punctuation,
/// without rephrasing or changing the user's actual words.
///
/// Works for any language: the prompt instructs the model to clean
/// filler words natural to the transcript's language and to reply
/// in the same language (not English), using the app's language setting.
///
/// This is intentionally separate from "Voice Edit" — it is not a
/// content transformation, only a speech-artifact cleanup.
enum DictationPolisher {

    static let maxTokens = 400

    /// Returns the polished transcript, or throws if the LLM call fails.
    /// The caller falls back to the raw transcript on any error.
    static func polish(transcript: String, llm: any LLMService) async throws -> String {
        let langCode = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let prompt = buildPrompt(transcript: transcript, langCode: langCode)
        let raw = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
        return cleaned(raw, fallback: transcript)
    }

    // MARK: - Prompt

    static func buildPrompt(transcript: String, langCode: String) -> String {
        let langInstruction: String
        if langCode == "en" {
            langInstruction = "Reply in English."
        } else {
            let locale = Locale(identifier: "en")
            let langName = locale.localizedString(forLanguageCode: langCode) ?? langCode
            langInstruction = "IMPORTANT: Reply ONLY in \(langName). Do NOT use English."
        }

        return """
        You are a transcription editor. Your only job is to clean up spoken text:
        1. Remove vocal hesitations and filler sounds that carry no semantic content in this language — sounds or words a speaker inserts while thinking, not as meaningful content. Use your understanding of the language to judge whether a word is a filler in context (e.g. "I like this" is meaningful; "I was, like, going" is a filler). Do NOT remove words that carry meaning even if they are sometimes used as fillers.
        2. Add punctuation (periods, commas, question marks). Capitalize the first word of each sentence.
        3. Do NOT rephrase, restructure, or change any actual words. Do NOT add or remove meaningful content.
        4. If the text is already clean, return it unchanged.
        5. Output ONLY the cleaned text — no explanations, no quotes, nothing else.
        6. \(langInstruction)

        Text: \(transcript)
        """
    }

    // MARK: - Output cleaning

    /// Strip any preamble the model might add (e.g. "Cleaned text: …") and
    /// fall back to the original transcript if the result is empty or clearly wrong.
    private static func cleaned(_ raw: String, fallback: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common model preambles: "Cleaned text:", "Output:", "Result:", etc.
        let preambles = ["Cleaned text:", "Output:", "Result:", "Here is", "Here's"]
        for prefix in preambles {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip surrounding quotes the model might add
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Sanity check: filler removal should reduce length slightly, punctuation
        // adds negligible characters. Allow 85%–120% of the original length.
        // Outside that window the model likely rephrased — fall back silently.
        let ratio = Double(result.count) / Double(max(fallback.count, 1))
        guard !result.isEmpty, ratio > 0.85, ratio < 1.2 else { return fallback }

        return result
    }
}
