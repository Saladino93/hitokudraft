import Foundation

enum OutputCleaner {
    // MARK: - Preamble/trailing patterns (for clean())

    private static let preamblePrefixes: [String] = [
        "sure", "certainly", "here is", "here's", "of course",
        "below is", "the corrected", "the edited", "the rewritten",
    ]

    private static let trailingPrefixes: [String] = [
        "note:", "please note", "i have", "changes made:",
    ]

    // MARK: - Model artifact patterns (compiled once for cleanModelOutput)

    // Step 1: Complete thinking blocks — <think>...</think> and variants
    private static let closedThinkingPattern: NSRegularExpression = {
        // Matches <think>, <thinking>, <|think|>, <|thinking|> ... </think>, </thinking>, etc.
        // Case-insensitive. [\s\S]*? is non-greedy to match smallest block.
        try! NSRegularExpression(
            pattern: #"<\|?think(?:ing)?\|?>\s*[\s\S]*?\s*<\|?/think(?:ing)?\|?>"#,
            options: .caseInsensitive
        )
    }()

    // Step 2: Unclosed thinking blocks — open tag with no matching close
    private static let unclosedThinkingPattern: NSRegularExpression = {
        // Greedy match from open tag to end of string (answer never arrived)
        try! NSRegularExpression(
            pattern: #"<\|?think(?:ing)?\|?>[\s\S]*$"#,
            options: .caseInsensitive
        )
    }()

    // Step 2b: Plain-text thinking blocks (e.g. "**Thinking Process:**\n1. ...")
    // Anchors on a "Thinking" header at start of line, matches through to double-newline.
    private static let plainTextThinkingPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?m)^\*{0,2}(?:Thinking|Thought|Reasoning|Analysis)(?:\s+Process)?:?\*{0,2}\s*\n[\s\S]*?(?=\n{2,})"#,
            options: .caseInsensitive
        )
    }()

    // Step 3: End-of-turn / special tokens that leaked into output
    private static let specialTokenPattern: NSRegularExpression = {
        // Matches any of the known delimiter tokens. We find the first and truncate.
        try! NSRegularExpression(
            pattern: #"<\|?end_of_turn\|?>|<\|im_end\|?>|<\|eot_id\|?>|<\|endoftext\|?>|\[/?INST\]|</s>"#,
            options: .caseInsensitive
        )
    }()

    // Step 4: Collapse 3+ consecutive newlines to exactly 2
    private static let excessiveNewlinesPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\n{3,}"#, options: [])
    }()

    // MARK: - cleanModelOutput

    /// Strips known LLM generation artifacts: thinking blocks, special tokens,
    /// excessive newlines. Pure function — same input always produces same output.
    static func cleanModelOutput(_ text: String) -> String {
        var result = text
        let fullRange = { NSRange(result.startIndex..., in: result) }

        // Step 1: Remove complete thinking blocks (open + content + close)
        result = closedThinkingPattern.stringByReplacingMatches(
            in: result, options: [], range: fullRange(), withTemplate: ""
        )

        // Step 2: Remove unclosed thinking blocks (open tag to end of string)
        result = unclosedThinkingPattern.stringByReplacingMatches(
            in: result, options: [], range: fullRange(), withTemplate: ""
        )

        // Step 2b: Remove plain-text thinking blocks ("**Thinking Process:**\n1. ...")
        result = plainTextThinkingPattern.stringByReplacingMatches(
            in: result, options: [], range: fullRange(), withTemplate: ""
        )

        // Step 3: Truncate at the first special token (everything after is garbage)
        if let match = specialTokenPattern.firstMatch(in: result, options: [], range: fullRange()) {
            let matchStart = match.range.location
            result = String(result[result.startIndex..<result.index(result.startIndex, offsetBy: matchStart)])
        }

        // Step 4: Trim whitespace, then collapse 3+ newlines to 2
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = excessiveNewlinesPattern.stringByReplacingMatches(
            in: result, options: [], range: fullRange(), withTemplate: "\n\n"
        )

        return result
    }

    // MARK: - Full cleaning pipeline

    // MARK: - Instruction-echo detection

    /// Strips the first line of output if it appears to be an echo of the user's instruction.
    /// Uses word overlap: if >60% of instruction words appear in the first line, it's an echo.
    /// Conservative threshold avoids false positives; safe for all model families.
    static func stripEcho(_ text: String, instruction: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let firstLine = lines.first, !firstLine.isEmpty else { return text }

        let instructionWords = Set(
            instruction.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }  // skip tiny words like "a", "to", "is"
        )
        guard !instructionWords.isEmpty else { return text }

        let firstLineWords = Set(
            firstLine.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
        )

        let overlap = instructionWords.intersection(firstLineWords).count
        let ratio = Double(overlap) / Double(instructionWords.count)

        if ratio > 0.6 {
            let remaining = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remaining.isEmpty ? text : remaining  // don't strip if nothing left
        }

        return text
    }

    // MARK: - Full cleaning pipeline

    /// Full output cleaning: model artifacts first, then preamble/fences/trailing notes.
    static func clean(_ text: String) -> String {
        // First strip model-level artifacts (thinking blocks, special tokens)
        let cleaned = cleanModelOutput(text)

        var lines = cleaned.components(separatedBy: .newlines)

        // Strip leading preamble lines
        while let first = lines.first {
            let lower = first.lowercased().trimmingCharacters(in: .whitespaces)
            if lower.isEmpty || preamblePrefixes.contains(where: { lower.hasPrefix($0) }) {
                lines.removeFirst()
            } else {
                break
            }
        }

        // Strip code fences
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return false }
            if trimmed.range(of: #"^[-=]{3,}$"#, options: .regularExpression) != nil {
                return false
            }
            return true
        }

        // Strip trailing note lines
        while let last = lines.last {
            let lower = last.lowercased().trimmingCharacters(in: .whitespaces)
            if lower.isEmpty || trailingPrefixes.contains(where: { lower.hasPrefix($0) }) {
                lines.removeLast()
            } else {
                break
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
