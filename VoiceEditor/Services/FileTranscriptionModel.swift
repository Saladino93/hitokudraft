import Foundation
import SwiftUI

/// Drives multi-file transcription for the Transcribe window: add files →
/// transcribe each (decode → 16 kHz mono → ~30 s chunks) → assemble text, and
/// optionally edit the selected transcript with the LLM ("Edit with Voice").
///
/// A failed/low-confidence chunk is skipped rather than aborting, so one noisy
/// segment can't lose the rest of a file.
@MainActor
final class FileTranscriptionModel: ObservableObject {

    enum Phase: Equatable { case pending, working, done, failed }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var phase: Phase = .pending
        var progress: Double = 0
        var resultText: String = ""
        var error: String?
        var name: String { url.lastPathComponent }
    }

    @Published var items: [Item] = []
    @Published var selectedID: Item.ID?
    @Published var isRunning = false
    @Published var statusText = ""

    // Transcriber choice: dedicated STT (default) or the AI model (Gemma, better
    // for mixed/many languages, slower). Only offered when the selected LLM has audio.
    @Published var useLLM = false

    // Edit-with-Voice bar state.
    @Published var showEditBar = false
    @Published var editCommand = ""
    @Published var isEditing = false
    @Published var isDictating = false

    private weak var coordinator: ConversationCoordinator?
    private var task: Task<Void, Never>?

    private static let chunkSamples = 30 * 16_000   // 30 s @ 16 kHz
    private static let minSamples = 16_000          // backend requires ≥ 1 s

    init(coordinator: ConversationCoordinator?) {
        self.coordinator = coordinator
    }

    // MARK: - Derived

    var selectedItem: Item? { items.first { $0.id == selectedID } }
    var pendingCount: Int { items.filter { $0.phase == .pending || $0.phase == .failed }.count }
    var hasResult: Bool { !(selectedItem?.resultText.isEmpty ?? true) }
    /// Whether the "transcribe with AI model (Gemma)" choice should be offered.
    var canUseLLM: Bool { coordinator?.selectedLLMSupportsAudio ?? false }

    /// Two-way binding to the selected file's transcript (editable + LLM-rewritable).
    var selectedResult: Binding<String> {
        Binding(
            get: { [weak self] in self?.selectedItem?.resultText ?? "" },
            set: { [weak self] newValue in
                guard let self, let i = self.index(of: self.selectedID) else { return }
                self.items[i].resultText = newValue
            }
        )
    }

    // MARK: - File list

    func addFiles(_ urls: [URL]) {
        let existing = Set(items.map(\.url))
        let fresh = urls.filter { $0.isFileURL && !existing.contains($0) }.map { Item(url: $0) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        if selectedID == nil { selectedID = items.first?.id }
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clearAll() {
        task?.cancel(); task = nil
        items = []
        selectedID = nil
        isRunning = false
        statusText = ""
        showEditBar = false
    }

    // MARK: - Transcription

    func transcribeAll() {
        guard let coordinator, !isRunning, pendingCount > 0 else { return }
        task?.cancel()
        isRunning = true
        statusText = "Preparing speech model…"
        task = Task { [weak self] in await self?.runAll(coordinator: coordinator) }
    }

    func cancel() {
        task?.cancel(); task = nil
        isRunning = false
        statusText = "Cancelled"
        for i in items.indices where items[i].phase == .working {
            items[i].phase = .pending
            items[i].progress = 0
        }
    }

    private func index(of id: Item.ID?) -> Int? {
        guard let id else { return nil }
        return items.firstIndex { $0.id == id }
    }

    private func runAll(coordinator: ConversationCoordinator) async {
        do {
            let stt: any STTService
            if useLLM {
                guard let llmSTT = try await coordinator.makeLLMTranscriptionSTT() else {
                    throw FileTranscriptionError.noTranscriptionModel
                }
                stt = llmSTT
            } else {
                guard let dedicated = try await coordinator.makeSttServiceForFile() else {
                    throw FileTranscriptionError.noTranscriptionModel
                }
                stt = dedicated
            }
            for item in items where item.phase == .pending || item.phase == .failed {
                try Task.checkCancellation()
                guard let idx = index(of: item.id) else { continue }
                items[idx].phase = .working
                items[idx].progress = 0
                items[idx].error = nil
                selectedID = item.id
                do {
                    let text = try await transcribeOne(url: item.url, stt: stt) { [weak self] frac in
                        guard let self, let i = self.index(of: item.id) else { return }
                        self.items[i].progress = frac
                        self.statusText = "Transcribing \(item.name) — \(Int(frac * 100))%"
                    }
                    if let i = index(of: item.id) {
                        items[i].resultText = text
                        items[i].phase = .done
                        items[i].progress = 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let i = index(of: item.id) {
                        items[i].phase = .failed
                        items[i].error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            statusText = "Done"
            isRunning = false
        } catch is CancellationError {
            isRunning = false
            statusText = "Cancelled"
        } catch {
            isRunning = false
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func transcribeOne(
        url: URL,
        stt: any STTService,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        let samples = try await Task.detached(priority: .userInitiated) {
            try await AudioFileDecoder.decodeToMono16k(url: url)
        }.value
        try Task.checkCancellation()

        var chunks: [[Float]] = []
        var i = 0
        while i < samples.count {
            let end = min(i + Self.chunkSamples, samples.count)
            chunks.append(Array(samples[i..<end]))
            i = end
        }
        guard !chunks.isEmpty else { throw AudioFileDecoder.DecodeError.empty }

        var pieces: [String] = []
        for (n, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            var s = chunk
            if s.count < Self.minSamples {
                s.append(contentsOf: repeatElement(0, count: Self.minSamples - s.count))
            }
            do {
                let t = try await stt.transcribe(samples: s).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { pieces.append(t) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Skip noisy / low-confidence / empty segment.
            }
            progress(Double(n + 1) / Double(chunks.count))
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Edit with Voice

    func applyEdit() {
        guard let coordinator, let sel = selectedItem, !sel.resultText.isEmpty, !isEditing else { return }
        let command = editCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let id = sel.id
        let text = sel.resultText
        isEditing = true
        Task { [weak self] in
            defer { self?.isEditing = false }
            do {
                let edited = try await coordinator.editText(text, instruction: command)
                guard let self, let i = self.index(of: id), !edited.isEmpty else { return }
                self.items[i].resultText = edited
                self.editCommand = ""
            } catch {
                self?.statusText = "Edit failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    func dictateCommand() {
        guard let coordinator, !isDictating else { return }
        isDictating = true
        Task { [weak self] in
            defer { self?.isDictating = false }
            if let spoken = try? await coordinator.dictateCommand(),
               !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self?.editCommand = spoken
            }
        }
    }
}

enum FileTranscriptionError: LocalizedError {
    case noTranscriptionModel

    var errorDescription: String? {
        switch self {
        case .noTranscriptionModel:
            return "No transcription model is loaded. Pick a speech model (e.g. Parakeet or Whisper) in Preferences, then try again."
        }
    }
}

/// Errors surfaced by `ConversationCoordinator.editText`.
enum TextEditError: LocalizedError {
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .textTooLong:
            return "This transcript is too long for the model's context window. Try a shorter file, or an edit that shortens the text (e.g. \"summarize\")."
        }
    }
}
