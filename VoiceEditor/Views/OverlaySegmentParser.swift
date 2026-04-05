import Foundation

/// Typed segment produced by the overlay segment parser.
///
/// Plain and math segments compose into a single SwiftUI Text; codeBlock and inlineCode
/// render with distinct visual treatment. Adding a new case forces a compiler error at
/// every rendering switch, preventing silent omissions.
///
/// Kept in a separate file (not nested inside DictationOverlayPanel) so unit tests
/// can exercise the parser logic without importing AppKit/SwiftUI.
enum TextSegment: Equatable {
    case plain(String)
    case math(String)                              // LaTeX expression (delimiters stripped)
    case codeBlock(language: String, code: String) // ```lang\ncode\n```
    case inlineCode(String)                        // `code`
}

// MARK: - Parser
//
// Priority (checked in order so long openers win over their prefixes):
//   1. Code block   ``` lang \n code \n ```
//   2. Inline code  `code`
//   3. Display math $$...$$
//   4. Inline math  $...$
//   5. Block math   \[...\]  or  \(...\)
//   6. Plain text

/// Splits a mixed text string into typed segments.
/// Unclosed delimiters are treated as plain text — no fallthrough mis-parse.
/// Returns `[.plain(text)]` when no special markers are found.
func parseSegments(_ text: String) -> [TextSegment] {
    var result: [TextSegment] = []
    var currentText = ""
    var i = text.startIndex

    while i < text.endIndex {
        let c = text[i]
        let next1 = text.index(after: i)

        // ── 1. Code block: ```lang\ncode\n``` ─────────────────────────────────
        if c == "`",
           next1 < text.endIndex, text[next1] == "`",
           let next2 = text.index(next1, offsetBy: 1, limitedBy: text.endIndex),
           next2 < text.endIndex, text[next2] == "`",
           let afterOpener = text.index(next2, offsetBy: 1, limitedBy: text.endIndex) {

            let lang: String
            let codeStart: String.Index
            if afterOpener < text.endIndex,
               let nlRange = text.range(of: "\n", range: afterOpener..<text.endIndex) {
                lang = String(text[afterOpener..<nlRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                codeStart = nlRange.upperBound
            } else {
                lang = ""
                codeStart = afterOpener
            }

            if let closeRange = text.range(of: "```", range: codeStart..<text.endIndex) {
                if !currentText.isEmpty { result.append(.plain(currentText)); currentText = "" }
                let code = String(text[codeStart..<closeRange.lowerBound])
                    .trimmingCharacters(in: .newlines)
                result.append(.codeBlock(language: lang, code: code))
                var end = closeRange.upperBound
                if end < text.endIndex, text[end] == "\n" { end = text.index(after: end) }
                i = end
                continue
            }
            // Unclosed fence → fall through to inline-code guard
        }

        // ── 2. Inline code: `code` ────────────────────────────────────────────
        if c == "`",
           !(next1 < text.endIndex && text[next1] == "`"),  // not the start of ```
           let closeRange = text.range(of: "`", range: next1..<text.endIndex) {
            if !currentText.isEmpty { result.append(.plain(currentText)); currentText = "" }
            result.append(.inlineCode(String(text[next1..<closeRange.lowerBound])))
            i = closeRange.upperBound
            continue
        }

        // ── 3. Display math: $$...$$ (checked before single-$) ───────────────
        if c == "$", next1 < text.endIndex, text[next1] == "$",
           let afterDD = text.index(next1, offsetBy: 1, limitedBy: text.endIndex),
           let closeRange = text.range(of: "$$", range: afterDD..<text.endIndex) {
            if !currentText.isEmpty { result.append(.plain(currentText)); currentText = "" }
            result.append(.math(String(text[afterDD..<closeRange.lowerBound])))
            i = closeRange.upperBound
            continue
        }

        // ── 4. Inline math: $...$ (else-if so same $ not re-examined) ─────────
        else if c == "$",
                let closeRange = text.range(of: "$", range: next1..<text.endIndex) {
            if !currentText.isEmpty { result.append(.plain(currentText)); currentText = "" }
            result.append(.math(String(text[next1..<closeRange.lowerBound])))
            i = closeRange.upperBound
            continue
        }

        // ── 5. Block math \[...\] or inline math \(...\) ──────────────────────
        if c == "\\", next1 < text.endIndex {
            let nc = text[next1]
            let (close, skip): (String, Int) = nc == "[" ? ("\\]", 1)
                                             : nc == "(" ? ("\\)", 1) : ("", 0)
            if skip > 0,
               let afterOpen = text.index(next1, offsetBy: skip, limitedBy: text.endIndex),
               let closeRange = text.range(of: close, range: afterOpen..<text.endIndex) {
                if !currentText.isEmpty { result.append(.plain(currentText)); currentText = "" }
                result.append(.math(String(text[afterOpen..<closeRange.lowerBound])))
                i = closeRange.upperBound
                continue
            }
        }

        // ── 6. Plain text ─────────────────────────────────────────────────────
        currentText.append(c)
        i = next1
    }

    if !currentText.isEmpty { result.append(.plain(currentText)) }
    return result.isEmpty ? [.plain(text)] : result
}
