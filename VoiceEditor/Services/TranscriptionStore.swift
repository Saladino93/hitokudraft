import Foundation
import os

/// Persists every voice interaction as a JSON file.
///
/// Files are stored in `~/Library/Application Support/HitokuDraft/transcriptions/`
/// with one file per interaction, named by ISO-8601 timestamp.
actor TranscriptionStore {
    static let shared = TranscriptionStore()

    private static let log = Logger(subsystem: "com.hitokudraft.transcriptions", category: "store")

    private let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HitokuDraft", isDirectory: true)
            .appendingPathComponent("transcriptions", isDirectory: true)
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Record

    /// The mode of the voice interaction.
    enum InteractionMode: String, Codable {
        case voiceEdit
        case dictation
        case grammarFix
        case action
    }

    /// A single recorded interaction.
    struct Record: Codable {
        let timestamp: Date
        let mode: InteractionMode
        let transcription: String
        let llmResponse: String?
        let activeApp: String?
        let modelName: String?
    }

    /// Save a voice interaction to disk.
    func save(
        mode: InteractionMode,
        transcription: String,
        llmResponse: String? = nil,
        activeApp: String? = nil,
        modelName: String? = nil
    ) {
        let record = Record(
            timestamp: Date(),
            mode: mode,
            transcription: transcription,
            llmResponse: llmResponse,
            activeApp: activeApp,
            modelName: modelName
        )

        do {
            let data = try encoder.encode(record)
            let filename = Self.filename(for: record.timestamp)
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            Self.log.info("Saved \(mode.rawValue) transcription: \(filename)")
        } catch {
            Self.log.error("Failed to save transcription: \(error.localizedDescription)")
        }
    }

    // MARK: - Query

    /// List all saved records, most recent first.
    func listAll() -> [Record] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Record.self, from: data)
            }
    }

    /// Number of saved transcriptions.
    var count: Int {
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        return files?.filter { $0.pathExtension == "json" }.count ?? 0
    }

    /// The on-disk directory path (for display in Settings).
    var directoryPath: String { directory.path }

    // MARK: - Helpers

    private static func filename(for date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        // Replace colons for filesystem safety: 2026-04-11T17:30:45Z → 2026-04-11T17-30-45Z.json
        return fmt.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            + ".json"
    }
}
