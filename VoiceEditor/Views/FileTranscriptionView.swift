import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Multi-file transcription window: drop/browse several files, transcribe them,
/// select any file to view its transcript, then optionally edit it with the LLM.
struct FileTranscriptionView: View {
    @Bindable var model: FileTranscriptionModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe Audio")
                .font(.system(size: 18, weight: .bold))

            dropZone

            if !model.items.isEmpty {
                fileList
            }

            if !model.items.isEmpty && model.canUseLLM {
                Picker("Transcribe with", selection: $model.useLLM) {
                    Text("Speech model").tag(false)
                    Text("AI model (Gemma)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRunning)
                if model.useLLM {
                    Text("Gemma transcribes directly. Better for mixed languages, slower than a speech model.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            controls

            if model.isRunning || !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.statusText.hasPrefix("Edit failed") ? .red : .secondary)
                    .lineLimit(2)
            }

            resultArea

            editBar
        }
        .padding(20)
        .frame(width: 552, height: 640)
        .background(WindowConfigurator())
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(height: 84)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    Text("Drop audio or video files here, or")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Add Files…") { browse() }
                        .controlSize(.small)
                }
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.isFileURL else { return }
                        Task { @MainActor in model.addFiles([url]) }
                    }
                }
                return true
            }
    }

    // MARK: - File list

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.items) { item in
                    fileRow(item)
                }
            }
        }
        .frame(height: 110)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06))
        )
    }

    private func fileRow(_ item: FileTranscriptionModel.Item) -> some View {
        HStack(spacing: 8) {
            statusIcon(item)
                .frame(width: 16)
            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if item.phase == .working {
                Text("\(Int(item.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                model.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.id == model.selectedID ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
    }

    @ViewBuilder
    private func statusIcon(_ item: FileTranscriptionModel.Item) -> some View {
        switch item.phase {
        case .pending:  Image(systemName: "circle").foregroundStyle(.secondary)
        case .working:  ProgressView().controlSize(.small)
        case .done:     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:   Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if model.isRunning {
                Button(role: .cancel) { model.cancel() } label: { Text("Cancel") }
            } else {
                Button { model.transcribeAll() } label: {
                    Label(model.pendingCount > 1 ? "Transcribe \(model.pendingCount)" : "Transcribe",
                          systemImage: "text.viewfinder")
                }
                .disabled(model.pendingCount == 0)
            }

            if !model.items.isEmpty {
                Button("Clear") { model.clearAll() }
                    .disabled(model.isRunning)
            }

            Spacer()

            if model.hasResult {
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { save() } label: { Label("Save…", systemImage: "square.and.arrow.up") }
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        if !model.items.isEmpty {
            TextEditor(text: model.selectedResult)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        } else {
            Spacer()
        }
    }

    // MARK: - Edit with Voice

    @ViewBuilder
    private var editBar: some View {
        if model.hasResult {
            Divider()
            if model.showEditBar {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Editing command — e.g. \"make it bullet points\"",
                                  text: $model.editCommand)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isEditing)
                            .onSubmit { model.applyEdit() }

                        Button { model.dictateCommand() } label: {
                            Image(systemName: model.isDictating ? "mic.fill" : "mic")
                                .foregroundStyle(model.isDictating ? Color.red : Color.primary)
                        }
                        .help("Dictate the editing command")
                        .disabled(model.isEditing)

                        Button("Apply") { model.applyEdit() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isEditing ||
                                      model.editCommand.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button {
                            model.showEditBar = false
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .help("Hide")
                    }

                    if model.isEditing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Rewriting with the loaded model…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if model.isDictating {
                        Text("Listening… speak your editing command.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Try: \"Turn into bullet points\", \"Fix punctuation\", \"Translate to French\"")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } else {
                Button { model.showEditBar = true } label: {
                    Label("Edit with Voice", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
            }
        }
    }

    // MARK: - Actions

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            model.addFiles(panel.urls)
        }
    }

    private func copy() {
        guard let text = model.selectedItem?.resultText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        guard let item = model.selectedItem else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(item.url.deletingPathExtension().lastPathComponent).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? item.resultText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Window configuration (Esc-to-close + activation tracking)

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ActivationPolicyManager.shared.trackWindow(window)
            window.standardWindowButton(.closeButton)?.keyEquivalent = "\u{1B}"
            window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = []
        }
    }
}
