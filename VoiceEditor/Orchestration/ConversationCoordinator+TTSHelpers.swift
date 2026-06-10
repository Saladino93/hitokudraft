import Foundation
import NaturalLanguage

// MARK: - TTS Helpers (chunk cleaning, number-to-words, language detection)

extension ConversationCoordinator {

    /// Strips TTS-unfriendly artifacts and converts numbers to words.
    /// Lightweight — runs per-chunk during streaming. The full OutputCleaner
    /// still runs on the final assembled text.
    func cleanChunkForTTS(_ chunk: String) -> String {
        // Fast path: every artifact below contains '<' or '`'. Most streamed chunks
        // are plain words — skip the 11 full-string scans for them.
        guard chunk.contains("<") || chunk.contains("`") else { return chunk }
        var t = chunk
        t = t.replacingOccurrences(of: "<think>", with: "")
        t = t.replacingOccurrences(of: "</think>", with: "")
        t = t.replacingOccurrences(of: "<|think|>", with: "")
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "<|assistant|>", with: "")
        t = t.replacingOccurrences(of: "<|end|>", with: "")
        t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        t = t.replacingOccurrences(of: "<|im_start|>", with: "")
        // Gemma 4 — residual tags that slip through the ThinkingBlockFilter
        t = t.replacingOccurrences(of: "<|channel>", with: "")
        t = t.replacingOccurrences(of: "<channel|>", with: "")
        t = t.replacingOccurrences(of: "<end_of_turn>", with: "")
        // Number-to-words conversion is now handled centrally in TTSService.prepareForSpeech().
        return t
    }

    /// Replaces digit sequences with their spelled-out equivalents.
    /// Handles integers and decimals. Uses the current locale for natural phrasing.
    static let spellOutFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .spellOut
        fmt.locale = Locale(identifier: "en_US")
        return fmt
    }()

    static func convertNumbersToWords(_ text: String) -> String {
        // Match sequences of digits, optionally with a decimal point (e.g. "3.14", "42", "1000")
        let pattern = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        // Process matches in reverse order to preserve indices
        let matches = pattern.matches(in: text, range: range)
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let numStr = String(result[swiftRange])
            if let number = Double(numStr),
               let spelled = spellOutFormatter.string(from: NSNumber(value: number)) {
                result.replaceSubrange(swiftRange, with: spelled)
            }
        }
        return result
    }

    // MARK: - TTS Language Detection

    /// Kokoro voice prefix → NLLanguage mapping.
    /// Each prefix is a two-letter code: first letter = language, second = gender (f/m).
    static let kokoroLanguageMap: [NLLanguage: String] = [
        .english: "af",      // American English female (default)
        .spanish: "ef",      // Spanish (LATAM) female
        .french: "ff",       // French female
        .hindi: "hf",        // Hindi female
        .italian: "if",      // Italian female
        .japanese: "jf",     // Japanese female
        .portuguese: "pf",   // Brazilian Portuguese female
        .simplifiedChinese: "zf",  // Mandarin Chinese female
        .traditionalChinese: "zf",
    ]

    /// Detects the dominant language of `text` and returns the best Kokoro female voice
    /// for that language. Returns nil if the language matches the user's current voice
    /// or if detection is ambiguous (< 80% confidence).
    func autoDetectKokoroVoice(for text: String, currentVoice: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let detected = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[detected],
              confidence >= 0.8 else {
            return nil  // Ambiguous — keep user's selection
        }

        // Find the prefix for the detected language.
        guard let targetPrefix = Self.kokoroLanguageMap[detected] else {
            return nil  // Unsupported language — keep user's selection
        }

        // If user's voice already matches the detected language, no change needed.
        if currentVoice.hasPrefix(targetPrefix) { return nil }

        // Find the first available female voice with the target prefix.
        let match = KokoroTTSProvider.femaleVoices.first { $0.hasPrefix(targetPrefix) }
        return match
    }
}
