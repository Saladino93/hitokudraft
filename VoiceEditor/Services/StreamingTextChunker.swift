/// Filters out model thinking blocks from an LLM token stream before TTS processing.
///
/// Gemma 4 uses `<|channel>thought\n...<channel|>` blocks for chain-of-thought reasoning.
/// These arrive as individual streaming tokens and must be suppressed from TTS output.
/// The filter uses a small rolling buffer to handle partial tag matches across chunk boundaries.
///
/// Create a fresh instance per voice edit (stateful across chunks, stateless between requests).
struct ThinkingBlockFilter {
    private var isInside = false
    private var buffer = ""

    private static let openTag = "<|channel>thought"
    private static let closeTag = "<channel|>"

    /// Feed a streaming chunk. Returns only the text that should be spoken
    /// (empty string when inside a thinking block).
    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var output = ""

        while true {
            if isInside {
                if let range = buffer.range(of: Self.closeTag) {
                    // Found close tag — discard everything up to and including it
                    buffer = String(buffer[range.upperBound...])
                    isInside = false
                    continue
                } else {
                    // Still inside thinking — keep only enough for partial close tag match
                    let keep = Self.closeTag.count - 1
                    if buffer.count > keep {
                        buffer = String(buffer.suffix(keep))
                    }
                    break
                }
            } else {
                if let range = buffer.range(of: Self.openTag) {
                    // Found open tag — output everything before it
                    output += buffer[buffer.startIndex..<range.lowerBound]
                    buffer = String(buffer[range.upperBound...])
                    isInside = true
                    continue
                } else {
                    // No open tag — output everything except last N chars (partial tag buffer)
                    let keep = Self.openTag.count - 1
                    let safeCount = max(0, buffer.count - keep)
                    if safeCount > 0 {
                        output += buffer.prefix(safeCount)
                        buffer = String(buffer.suffix(buffer.count - safeCount))
                    }
                    break
                }
            }
        }

        return output
    }

    /// Flush any remaining buffered text at end of generation.
    /// Discards buffer if still inside a thinking block (unclosed tag).
    mutating func flush() -> String {
        let remaining = isInside ? "" : buffer
        buffer = ""
        isInside = false
        return remaining
    }
}

/// Extracts speakable text segments from an LLM token stream for TTS enqueuing.
///
/// Uses a priority hierarchy of split points so TTS starts quickly while
/// keeping chunks long enough for smooth, natural-sounding playback:
///
/// 1. **Sentence end** (`.!?` + whitespace, ≥12 chars) — highest quality, fast first utterance
/// 2. **Newline** (`\n` after ≥20 chars) — handles lists, bullet points
/// 3. **Word boundary** (space after ≥120 chars, or after a long-buffer guard) — fallback for wall-of-text
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

    /// Forces a first-segment split after a max-latency threshold.
    /// Only applies before any segment has been emitted.
    mutating func forceFirstSplit(minChars: Int) -> [String] {
        guard !hasEmitted else { return [] }
        guard let split = forceWordBoundarySplit(minChars: minChars) else { return [] }
        let segment = String(buffer[buffer.startIndex..<split])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isEmpty { return [] }
        let remaining = buffer[split...]
            .drop(while: { $0.isWhitespace || $0.isNewline })
        buffer = String(remaining)
        hasEmitted = true
        return [segment]
    }

    // MARK: - Split strategies

    /// Strategy 1: Sentence-ending punctuation (`.!?`) followed by whitespace.
    /// First segment: ≥12 chars (fast start). Subsequent: ≥30 chars (smoother).
    private func sentenceEndSplit() -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        return findTerminator(in: terminators, minChars: hasEmitted ? 30 : 12)
    }

    /// Strategy 2: Newline after threshold chars. Handles lists, bullet points, multi-line output.
    /// First segment: ≥20 chars. Subsequent: ≥50 chars.
    private func newlineSplit() -> String.Index? {
        let minChars = hasEmitted ? 50 : 20
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
    /// First segment: ≥120 chars. Subsequent: ≥160 chars.
    /// Long-buffer guard lowers the threshold if the buffer grows too large.
    private func wordBoundarySplit() -> String.Index? {
        let baseMinChars = hasEmitted ? 160 : 120
        let maxBuffer = hasEmitted ? 320 : 240
        let minChars = buffer.count >= maxBuffer ? max(80, baseMinChars - 40) : baseMinChars
        guard buffer.count >= minChars else { return nil }
        let searchStart = buffer.index(buffer.startIndex, offsetBy: minChars - 1, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        guard searchStart < buffer.endIndex else { return nil }
        if let spaceIdx = buffer[searchStart...].firstIndex(of: " ") {
            return spaceIdx
        }
        return nil
    }

    /// Force-split on a word boundary after `minChars` (first segment only).
    private func forceWordBoundarySplit(minChars: Int) -> String.Index? {
        guard buffer.count >= minChars else { return nil }
        let searchStart = buffer.index(buffer.startIndex, offsetBy: minChars - 1, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        guard searchStart < buffer.endIndex else { return nil }
        return buffer[searchStart...].firstIndex(of: " ")
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
