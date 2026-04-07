import Foundation

/// A conversation is a sequence of messages with metadata.
/// Persisted as JSON files in ~/Library/Application Support/HitokuDraft/conversations/
struct Conversation: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    /// The model used for this conversation (for display/filtering).
    var modelName: String?

    init(title: String = "New Conversation", modelName: String? = nil) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.modelName = modelName
    }

    // MARK: - Public Methods

    /// Appends a message and updates the timestamp.
    mutating func append(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
        // Auto-title from first user message if still default
        if title == "New Conversation", message.role == .user {
            title = String(message.content.prefix(50))
        }
    }

    /// Returns the last N messages for context injection into prompts.
    /// Budget-aware: stops adding messages when total characters exceed budget.
    func recentMessages(maxCount: Int = 10, charBudget: Int = 4000) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var totalChars = 0
        for message in messages.reversed() {
            let chars = message.content.count
            if totalChars + chars > charBudget && !result.isEmpty { break }
            result.insert(message, at: 0)
            totalChars += chars
            if result.count >= maxCount { break }
        }
        return result
    }
}
