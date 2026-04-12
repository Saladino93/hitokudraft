import AppKit
import SwiftUI

/// Renders text in the overlay with support for:
/// - Plain text with ghosting (solid committed part + dim in-progress tail)
/// - TTS sentence highlighting (current segment bright, rest dimmed)
/// - Complex content: LaTeX math + syntax-highlighted code blocks
struct OverlayTextRenderer: View {
    let text: String
    let maxLines: Int
    let textAreaHeight: CGFloat
    var speakingSegment: String = ""
    var isGhosting: Bool = false

    private var segments: [TextSegment] { parseSegments(text) }

    private var hasComplexContent: Bool {
        segments.contains {
            if case .plain = $0 { return false }
            return true
        }
    }

    var body: some View {
        if !hasComplexContent {
            plainTextView
        } else if maxLines == 1 {
            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            complexContentView
        }
    }

    // MARK: - Plain text path

    @ViewBuilder
    private var plainTextView: some View {
        if maxLines == 1 {
            ghostedText(singleLine: true)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    ghostedText(singleLine: false)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("textBottom")
                }
                .frame(height: textAreaHeight)
                .clipped()
                // Auto-scroll only during TTS playback (follows the highlighted segment).
                // Does NOT scroll during generation — user reads freely.
                .onChange(of: speakingSegment) {
                    if !speakingSegment.isEmpty {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("textBottom", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ghostedText(singleLine: Bool) -> some View {
        let baseFont = Font.system(size: 15, weight: .medium, design: .rounded)

        if !speakingSegment.isEmpty,
           let range = text.range(of: speakingSegment, options: .literal) {
            let before = text[text.startIndex..<range.lowerBound]
            let current = text[range]
            let after = text[range.upperBound...]
            let view = Text(before).foregroundColor(.white.opacity(0.4))
                + Text(current).foregroundColor(.white).fontWeight(.semibold)
                + Text(after).foregroundColor(.white.opacity(0.4))
            return view
                .font(baseFont)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        }

        let (solid, ghost) = ghostSplit(from: text)
        let view: Text
        if ghost.isEmpty || !isGhosting {
            view = Text(text).foregroundStyle(.white.opacity(0.92))
        } else {
            view = Text(solid).foregroundStyle(.white.opacity(0.92))
                + Text(ghost).foregroundStyle(.white.opacity(singleLine ? 0.45 : 0.5))
        }

        return view
            .font(baseFont)
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    private func ghostSplit(from text: String) -> (String, String) {
        guard isGhosting else { return (text, "") }
        let boundaries: CharacterSet = {
            var set = CharacterSet(charactersIn: ".!?！。？")
            set.insert(charactersIn: "\n")
            return set
        }()
        if let idx = text.unicodeScalars.lastIndex(where: { boundaries.contains($0) }) {
            let next = text.unicodeScalars.index(after: idx)
            if next < text.unicodeScalars.endIndex {
                return (String(text.unicodeScalars[...idx]),
                        String(text.unicodeScalars[next...]))
            }
        }
        return ("", text)
    }

    // MARK: - Complex rendering (math + code blocks)

    private enum SegmentGroup {
        case inline([TextSegment])
        case codeBlock(language: String, code: String)
    }

    private var groupedSegments: [SegmentGroup] {
        var groups: [SegmentGroup] = []
        var accumInline: [TextSegment] = []
        for seg in segments {
            switch seg {
            case .plain, .math, .inlineCode:
                accumInline.append(seg)
            case .codeBlock(let lang, let code):
                if !accumInline.isEmpty { groups.append(.inline(accumInline)); accumInline = [] }
                groups.append(.codeBlock(language: lang, code: code))
            }
        }
        if !accumInline.isEmpty { groups.append(.inline(accumInline)) }
        return groups
    }

    @ViewBuilder
    private var complexContentView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(groupedSegments.enumerated()), id: \.offset) { _, group in
                    switch group {
                    case .inline(let segs):
                        buildInlineText(from: segs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .codeBlock(let lang, let code):
                        OverlayCodeBlockView(language: lang, code: code)
                    }
                }
            }
        }
        .frame(height: max(textAreaHeight, 44))
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildInlineText(from segs: [TextSegment]) -> Text {
        segs.reduce(Text("")) { acc, seg in
            switch seg {
            case .plain(let s):
                return acc + Text(s)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            case .math(let expr):
                if let rendered = MathView.renderToImage(
                    latex: expr, fontSize: 15,
                    color: NSColor.white.withAlphaComponent(0.92)
                ) {
                    return acc + Text(Image(nsImage: rendered.image))
                        .baselineOffset(-rendered.descent)
                } else {
                    return acc + Text(expr)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            case .inlineCode(let code):
                return acc + Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            case .codeBlock:
                return acc
            }
        }
    }
}

// MARK: - Code Block View

struct OverlayCodeBlockView: View {
    let language: String
    let code: String

    private var highlightedText: AttributedString? {
        let ns = CodeHighlighter.highlight(code: code, language: language)
        return try? AttributedString(ns, including: \.appKit)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if let attr = highlightedText {
                    Text(attr)
                } else {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
