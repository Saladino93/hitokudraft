import Foundation

/// A single message in a conversation -- user voice command, assistant response, or tool result.
struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    /// For VLM conversations -- screenshots or images associated with this message.
    /// Stored as PNG data for persistence.
    var imageData: [Data]?

    /// Tool calls made by the assistant in this message (Phase 4).
    var toolCalls: [ToolCall]?

    /// Result of a tool execution (when role == .tool).
    var toolResultName: String?

    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    // MARK: - Convenience Initializers

    static func user(_ content: String, images: [Data]? = nil) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, content: content, timestamp: Date(), imageData: images)
    }

    static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, content: content, timestamp: Date())
    }

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .system, content: content, timestamp: Date())
    }

    static func toolResult(name: String, content: String) -> ChatMessage {
        var msg = ChatMessage(id: UUID(), role: .tool, content: content, timestamp: Date())
        msg.toolResultName = name
        return msg
    }
}

/// Represents a tool call requested by the LLM (Phase 4 -- web search, URL fetch, etc.)
struct ToolCall: Codable, Sendable {
    let name: String
    let arguments: [String: String]
}
