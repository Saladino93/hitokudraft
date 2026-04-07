import Foundation

/// Persistence layer for conversations. JSON file-based -- no database dependency.
/// Each conversation is stored as a separate JSON file for simplicity.
protocol ChatStoreProtocol: Sendable {
    func save(_ conversation: Conversation) async throws
    func load(id: UUID) async throws -> Conversation
    func listRecent(limit: Int) async throws -> [Conversation]
    func delete(id: UUID) async throws
}

actor ChatStore: ChatStoreProtocol {

    // MARK: - Properties

    private let directory: URL

    // MARK: - Initialization

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport
            .appendingPathComponent("HitokuDraft")
            .appendingPathComponent("conversations")
    }

    // MARK: - Public Methods

    func save(_ conversation: Conversation) async throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(conversation)
        try data.write(to: fileURL(for: conversation.id), options: .atomic)
    }

    func load(id: UUID) async throws -> Conversation {
        let data = try Data(contentsOf: fileURL(for: id))
        return try JSONDecoder().decode(Conversation.self, from: data)
    }

    func listRecent(limit: Int) async throws -> [Conversation] {
        try ensureDirectory()
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }

        // Sort by modification date, most recent first
        let sorted = files.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }

        return try sorted.prefix(limit).compactMap { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Conversation.self, from: data)
        }
    }

    func delete(id: UUID) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private Methods

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
