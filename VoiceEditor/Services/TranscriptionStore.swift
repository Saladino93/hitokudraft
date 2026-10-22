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
    ///
    /// The `context*` fields capture exactly what the model was given before it
    /// answered, so a log is falsifiable: you can see whether a bad answer came
    /// from a bad screen read, the wrong model, or the model itself. (Optional, so
    /// older logs without them still decode.)
    struct Record: Codable {
        let timestamp: Date
        let mode: InteractionMode
        let transcription: String
        let llmResponse: String?
        let activeApp: String?
        let modelName: String?
        /// Backend that answered: "mlx" or "litert".
        var modelBackend: String?
        /// Context mode at capture time: "off" / "standard" / "advanced".
        var contextMode: String?
        /// Where the captured text came from: "accessibility" / "ocr" / "titleOnly" / "none".
        var contextSource: String?
        /// The exact screen-context text block injected into the prompt (what the model saw).
        var contextText: String?
        /// Whether a screenshot was sent to the model (vision).
        var hadScreenshot: Bool?

        // Latency split, in milliseconds. Lets a log show where the time went.
        /// Screen context capture.
        var latencyContextMs: Int?
        /// Final speech transcription after you stop talking (excludes talk time).
        var latencySttMs: Int?
        /// Time to the model's first token.
        var latencyFirstTokenMs: Int?
        /// Full model generation.
        var latencyModelMs: Int?
        /// Pasting or showing the result.
        var latencyInsertMs: Int?
        /// Hotkey press to result on screen (includes the time you spent talking).
        var latencyTotalMs: Int?
    }

    /// Save a voice interaction to disk.
    /// No-op when the user disabled "Save history" (Settings → History).
    /// Gated here — the single choke point — so every pipeline (voice edit,
    /// dictation, grammar fix, action mode) respects the setting.
    func save(
        mode: InteractionMode,
        transcription: String,
        llmResponse: String? = nil,
        activeApp: String? = nil,
        modelName: String? = nil,
        modelBackend: String? = nil,
        contextMode: String? = nil,
        contextSource: String? = nil,
        contextText: String? = nil,
        hadScreenshot: Bool? = nil,
        latencyContextMs: Int? = nil,
        latencySttMs: Int? = nil,
        latencyFirstTokenMs: Int? = nil,
        latencyModelMs: Int? = nil,
        latencyInsertMs: Int? = nil,
        latencyTotalMs: Int? = nil
    ) {
        guard Self.savingEnabled else { return }
        let record = Record(
            timestamp: Date(),
            mode: mode,
            transcription: transcription,
            llmResponse: llmResponse,
            activeApp: activeApp,
            modelName: modelName,
            modelBackend: modelBackend,
            contextMode: contextMode,
            contextSource: contextSource,
            contextText: contextText,
            hadScreenshot: hadScreenshot,
            latencyContextMs: latencyContextMs,
            latencySttMs: latencySttMs,
            latencyFirstTokenMs: latencyFirstTokenMs,
            latencyModelMs: latencyModelMs,
            latencyInsertMs: latencyInsertMs,
            latencyTotalMs: latencyTotalMs
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

    /// Whether saving is enabled (Settings → History → "Save history").
    /// Defaults to true when the key is absent (preserves pre-toggle behavior).
    nonisolated static var savingEnabled: Bool {
        UserDefaults.standard.object(forKey: "saveHistory").flatMap { $0 as? Bool } ?? true
    }

    // MARK: - Query

    /// A record paired with its on-disk file, so UI rows can delete the right file.
    struct Entry: Identifiable {
        let url: URL
        let record: Record
        var id: String { url.lastPathComponent }
    }

    /// List all saved entries, most recent first.
    func listEntries() -> [Entry] {
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
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(Record.self, from: data) else { return nil }
                return Entry(url: url, record: record)
            }
    }

    /// List all saved records, most recent first.
    func listAll() -> [Record] {
        listEntries().map(\.record)
    }

    // MARK: - Manage

    /// Delete a single saved interaction.
    func delete(_ entry: Entry) {
        do {
            try FileManager.default.removeItem(at: entry.url)
        } catch {
            Self.log.error("Failed to delete transcription \(entry.url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Delete every saved interaction.
    func clearAll() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            Self.log.error("Failed to list transcriptions for clearing: \(error.localizedDescription)")
            return
        }
        var failures = 0
        for url in files where url.pathExtension == "json" {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures += 1
                Self.log.error("Failed to delete transcription \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if failures == 0 {
            Self.log.info("Cleared all saved transcriptions")
        } else {
            Self.log.error("Clear all finished with \(failures) file(s) not deleted")
        }
    }

    /// Export the full history as a single JSON array.
    func exportAll(to destination: URL) throws {
        let data = try encoder.encode(listAll())
        try data.write(to: destination, options: .atomic)
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
