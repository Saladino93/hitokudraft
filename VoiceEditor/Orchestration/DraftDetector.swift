import Foundation

enum DraftDetector {
    private static let triggers: Set<String> = [
        "draft", "write", "compose", "create", "generate",
    ]

    private static let contentSignals: Set<String> = [
        "email", "letter", "message", "report", "memo",
        "summary", "paragraph", "document", "essay",
        "list", "note", "reminder", "outline", "template",
    ]

    static func isDraftCommand(_ command: String) -> Bool {
        let words = command.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }

        // Check first 3 words for trigger verbs
        if words.prefix(3).contains(where: { triggers.contains($0) }) {
            return true
        }

        // Check anywhere for content signals
        return words.contains(where: { contentSignals.contains($0) })
    }
}
