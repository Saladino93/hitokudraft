import Foundation

/// How much screen context to capture before an LLM call.
enum ContextAwareMode: String, CaseIterable {
    case off, standard, advanced
}

/// Where the captured context came from.
enum ContextSource: String {
    case accessibility, ocr, titleOnly, none
}

/// Snapshot of the user's screen context at capture time.
struct ScreenContext {
    // Primary (focused) app
    var appName: String?
    var windowTitle: String?
    var selectedText: String?
    var focusedText: String?
    var source: ContextSource = .none

    // Background app (Advanced mode only)
    var backgroundAppName: String?
    var backgroundWindowTitle: String?
    var backgroundText: String?

    /// Broader document text from PDFKit or AppleScript (Advanced mode only).
    /// Nil when the app is not supported or has no text layer (scanned PDFs fall back to OCR).
    var documentContext: String?

    /// Formatted block for injection into an LLM prompt, or nil when empty.
    var promptBlock: String? {
        var lines: [String] = []

        if let app = appName {
            let hasBackground = backgroundAppName != nil
            var header = hasBackground ? "Focused app: \(app)" : "App: \(app)"
            if let title = windowTitle { header += " — \(title)" }
            lines.append(header)
        }

        if let sel = selectedText, !sel.isEmpty {
            lines.append("Selected text:\n\(String(sel.prefix(2000)))")
        }
        if let focused = focusedText, !focused.isEmpty {
            let label = selectedText != nil ? "Surrounding page text" : "Visible text"
            lines.append("\(label):\n\(String(focused.prefix(2000)))")
        }
        if let doc = documentContext, !doc.isEmpty {
            lines.append("Broader document text (adjacent pages/body):\n\(doc)")
        }

        // Background app context
        if let bgApp = backgroundAppName {
            var bgHeader = "Background app: \(bgApp)"
            if let bgTitle = backgroundWindowTitle { bgHeader += " — \(bgTitle)" }
            lines.append(bgHeader)
            if let bgText = backgroundText, !bgText.isEmpty {
                lines.append("Visible text:\n\(String(bgText.prefix(2000)))")
            }
        }

        guard !lines.isEmpty else { return nil }

        if let hint = AppDomainHint.hint(appName: appName, windowTitle: windowTitle) {
            lines.append("[Hint: \(hint)]")
        }

        return """
        [Screen Context - use only if relevant to the user's request]
        \(lines.joined(separator: "\n"))
        [End Screen Context]
        """
    }

    var isEmpty: Bool { promptBlock == nil }
}
