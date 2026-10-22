import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// Settings → History: browse, search, and manage saved voice interactions.
/// Backed by TranscriptionStore (one JSON file per interaction, local only).
struct HistorySettingsTab: View {
    private static let log = Logger(subsystem: "com.hitokudraft.app", category: "HistorySettingsTab")

    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("historyIncludesContext") private var includeContext = false
    /// 0 = keep everything (default). Read by TranscriptionStore on each save.
    @AppStorage(TranscriptionStore.maxEntriesKey) private var maxEntries = 0

    /// Retention choices offered in the Keep picker (0 = all entries).
    private static let retentionOptions = [0, 100, 500, 1000]

    @State private var entries: [TranscriptionStore.Entry] = []
    @State private var searchText = ""
    @State private var confirmClearAll = false
    @State private var storePath = ""

    /// Cached — DateFormatter construction is expensive; rows render in a list.
    private static let rowDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM · HH:mm"
        return fmt
    }()

    private var filtered: [TranscriptionStore.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.record.transcription.localizedCaseInsensitiveContains(query)
                || ($0.record.llmResponse?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search + Clear All
            HStack(spacing: 10) {
                TextField(L("history.search_placeholder"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button(L("history.clear_all")) { confirmClearAll = true }
                    .disabled(entries.isEmpty)
            }

            // Save-history toggle
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("history.save_toggle"))
                        .font(.subheadline.weight(.medium))
                    Text(L("history.save_caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $saveHistory)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            // Include-screen-context toggle (TranscriptionStore drops contextText when off)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("history.include_context"))
                        .font(.subheadline.weight(.medium))
                    Text(L("history.include_context_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $includeContext)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!saveHistory)

            // Retention limit (TranscriptionStore prunes after each save when > 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("history.retention_label"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: $maxEntries) {
                    ForEach(Self.retentionOptions, id: \.self) { option in
                        Text(retentionTitle(option)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!saveHistory)

            Divider()

            // Entry list
            if filtered.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text(entries.isEmpty ? L("history.empty") : L("history.no_matches"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Footer: path + Show in Folder + Export
            HStack(spacing: 10) {
                Text(storePath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("history.show_in_folder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: storePath)
                }
                Button(L("history.export")) { exportHistory() }
                    .disabled(entries.isEmpty)
            }
        }
        .padding(20)
        .task { await reload() }
        .confirmationDialog(
            L("history.clear_confirm_title"),
            isPresented: $confirmClearAll
        ) {
            Button(L("history.clear_confirm_button"), role: .destructive) {
                Task {
                    await TranscriptionStore.shared.clearAll()
                    await reload()
                }
            }
        } message: {
            Text(L("history.clear_confirm_message"))
        }
    }

    // MARK: - Row

    private func row(for entry: TranscriptionStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.rowDateFormatter.string(from: entry.record.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modeLabel(entry.record.mode))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("history.copy")) { copy(entry) }
                    .font(.caption)
                Button(L("history.delete")) {
                    Task {
                        await TranscriptionStore.shared.delete(entry)
                        entries.removeAll { $0.id == entry.id }
                    }
                }
                .font(.caption)
            }

            Text(entry.record.transcription)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let response = entry.record.llmResponse, !response.isEmpty {
                Text(response)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Actions

    private func retentionTitle(_ option: Int) -> String {
        option == 0
            ? L("history.retention_unlimited")
            : String(format: L("history.retention_entries"), option)
    }

    private func reload() async {
        entries = await TranscriptionStore.shared.listEntries()
        storePath = await TranscriptionStore.shared.directoryPath
    }

    /// Copies the interaction's product: the model's answer when there is one,
    /// otherwise the raw transcript (dictation).
    private func copy(_ entry: TranscriptionStore.Entry) {
        let text = entry.record.llmResponse?.isEmpty == false
            ? entry.record.llmResponse! : entry.record.transcription
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HitokuDraft-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await TranscriptionStore.shared.exportAll(to: url)
            } catch {
                Self.log.error("History export failed: \(error.localizedDescription)")
            }
        }
    }

    private func modeLabel(_ mode: TranscriptionStore.InteractionMode) -> String {
        switch mode {
        case .voiceEdit: return L("history.mode.voice_edit")
        case .dictation: return L("history.mode.dictation")
        case .grammarFix: return L("history.mode.grammar_fix")
        case .action: return L("history.mode.action")
        }
    }
}
