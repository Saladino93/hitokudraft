/// Extracts speakable text segments from an LLM token stream for TTS enqueuing.
///
/// Uses a priority hierarchy of split points so TTS starts quickly while
/// keeping chunks long enough for smooth, natural-sounding playback:
///
/// 1. **Sentence end** (`.!?` + whitespace, ≥20 chars) — highest quality, fast first utterance
/// 2. **Newline** (`\n` after ≥40 chars) — handles lists, bullet points
/// 3. **Word boundary** (space after ≥120 chars) — fallback for wall-of-text
///
/// Clause breaks (commas, semicolons) are intentionally NOT used as split points
/// because they produce fragments that are too short, causing audible gaps between
/// TTS utterances — especially noticeable with autoregressive backends like PocketTTS.
///
/// All splits happen at natural boundaries — never mid-word.
/// Create a fresh instance per voice edit (stateless between requests).
struct StreamingTextChunker {

    private var buffer = ""
    /// Tracks whether we've emitted at least one segment.
    /// First segment uses lower thresholds for faster TTS start.
    private var hasEmitted = false

    /// Appends `chunk` (typically one or a few LLM tokens) to the internal buffer
    /// and returns any speakable segments that can be extracted.
    mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        let segments = extractSegments()
        if !segments.isEmpty { hasEmitted = true }
        return segments
    }

    /// Returns any remaining text in the buffer, trimmed.
    /// Call once after the LLM stream ends to flush the last partial segment.
    mutating func flush() -> String? {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }

    // MARK: - Private

    /// Scans the buffer for the highest-priority split point and extracts segments.
    private mutating func extractSegments() -> [String] {
        var segments: [String] = []

        while true {
            guard let split = findBestSplit() else { break }
            let segment = String(buffer[buffer.startIndex..<split])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }
            // Advance past the split point and any leading whitespace/newlines.
            let remaining = buffer[split...]
                .drop(while: { $0.isWhitespace || $0.isNewline })
            buffer = String(remaining)
        }

        return segments
    }

    /// Returns the best split index in the buffer, or nil if no split is possible yet.
    /// Checks strategies in priority order; the first match wins.
    private func findBestSplit() -> String.Index? {
        sentenceEndSplit()
            ?? newlineSplit()
            ?? wordBoundarySplit()
    }

    // MARK: - Split strategies

    /// Strategy 1: Sentence-ending punctuation (`.!?`) followed by whitespace.
    /// First segment: ≥15 chars (fast start). Subsequent: ≥30 chars (smoother).
    private func sentenceEndSplit() -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        return findTerminator(in: terminators, minChars: hasEmitted ? 30 : 15)
    }

    /// Strategy 2: Newline after threshold chars. Handles lists, bullet points, multi-line output.
    /// First segment: ≥25 chars. Subsequent: ≥50 chars.
    private func newlineSplit() -> String.Index? {
        let minChars = hasEmitted ? 50 : 25
        guard buffer.count >= minChars else { return nil }
        let searchStart = buffer.index(buffer.startIndex, offsetBy: minChars - 1, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        guard searchStart < buffer.endIndex else { return nil }
        if let nlIdx = buffer[searchStart...].firstIndex(of: "\n") {
            return nlIdx
        }
        return nil
    }

    /// Strategy 3: Any word boundary (space) after threshold chars. Fallback for wall-of-text
    /// with no sentence-ending punctuation or newlines.
    /// First segment: ≥60 chars. Subsequent: ≥120 chars.
    private func wordBoundarySplit() -> String.Index? {
        let minChars = hasEmitted ? 120 : 60
        guard buffer.count >= minChars else { return nil }
        let searchStart = buffer.index(buffer.startIndex, offsetBy: minChars - 1, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        guard searchStart < buffer.endIndex else { return nil }
        if let spaceIdx = buffer[searchStart...].firstIndex(of: " ") {
            return spaceIdx
        }
        return nil
    }

    // MARK: - Helpers

    /// Characters that confirm a sentence boundary after `.!?` besides whitespace.
    /// Closing quotes and parens are common in LLM output (e.g. `"Hello."` or `(done.)`).
    private static let closingChars: Set<Character> = ["\"", "\u{201D}", ")", "]"]

    /// Scans the buffer for any character in `terminators` followed by whitespace, a closing
    /// character, or buffer end (when enough text has accumulated).
    private func findTerminator(in terminators: Set<Character>, minChars: Int) -> String.Index? {
        var searchStart = buffer.startIndex

        while searchStart < buffer.endIndex {
            guard let idx = buffer[searchStart...].firstIndex(where: { terminators.contains($0) }) else {
                return nil
            }
            let afterTerminator = buffer.index(after: idx)
            let length = buffer.distance(from: buffer.startIndex, to: afterTerminator)

            guard length >= minChars else {
                searchStart = afterTerminator
                continue
            }

            if afterTerminator < buffer.endIndex {
                let next = buffer[afterTerminator]
                // Accept whitespace, newline, or closing quote/paren after terminator.
                guard next.isWhitespace || next.isNewline
                        || Self.closingChars.contains(next) else {
                    searchStart = afterTerminator
                    continue
                }
            }
            // else: terminator is at buffer end — split now. The minChars threshold
            // already filters abbreviations like "Dr." (< 15 chars). In streaming,
            // this avoids waiting an extra token for the whitespace to arrive.

            return afterTerminator
        }
        return nil
    }
}
