import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @ObservedObject var modelManager: ModelManager

    init(coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        self.modelManager = coordinator.modelManager
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            modelTab
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            hotkeysTab
                .tabItem {
                    Label("Hotkeys", systemImage: "keyboard")
                }
        }
        .frame(width: 450, height: 320)
        .background(WindowActivator())
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            HStack {
                VStack(alignment: .leading) {
                    Text("Accessibility")
                    Text("Required for text capture & hotkeys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.permissions.accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant") {
                        coordinator.permissions.requestAccessibility()
                    }
                }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Microphone")
                    Text("Required for voice commands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.permissions.microphoneGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant") {
                        Task { await coordinator.permissions.requestMicrophone() }
                    }
                }
            }

            if !coordinator.permissions.allGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tip: After clicking Grant, find VoiceEditor in System Settings and toggle it on.")
                    Text("Running from: \(Bundle.main.bundlePath)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Divider()

            setupStatusView

            if coordinator.permissions.allGranted && modelManager.llmReady {
                Divider()
                readyHintsView
            }
        }
        .padding()
    }

    @ViewBuilder
    private var readyHintsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ready to use", systemImage: "hand.thumbsup.fill")
                .foregroundStyle(.green)
                .font(.headline)

            HotkeyHintRow(label: "Voice Edit", shortcutName: .voiceEdit)
            HotkeyHintRow(label: "Grammar Fix", shortcutName: .grammarFix)
            HotkeyHintRow(label: "Dictation", shortcutName: .dictation)

            Text("You'll hear a sound when recording starts and when the edit is done.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var setupStatusView: some View {
        switch coordinator.state {
        case .downloading:
            DownloadProgressView(
                progress: modelManager.llmProgress,
                statusMessage: modelManager.statusMessage
            )
        case .warmingUp:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Warming up models...")
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry Setup") {
                    Task { await coordinator.setup() }
                }
            }
        default:
            if modelManager.llmReady && modelManager.sttReady {
                Label("All models loaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if modelManager.llmReady {
                Label("LLM ready — STT model failed to load", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Button("Download Models & Set Up") {
                    Task { await coordinator.setup() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Model

    private var modelTab: some View {
        Form {
            Label(
                "AI models can make mistakes. Review all outputs before use.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Section {
                Picker("Model", selection: $modelManager.selectedModel) {
                    ForEach(ModelRegistry.availableModels) { model in
                        Label(
                            model.name,
                            systemImage: model.isLocal ? "folder" : "cloud"
                        )
                        .tag(model)
                    }
                }
                .onChange(of: modelManager.selectedModel) {
                    Task { await coordinator.switchModel() }
                }

                LabeledContent("Source") {
                    Text(modelManager.selectedModel.isLocal ? "Local" : "HuggingFace")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Directory") {
                    let dir = modelCacheDirectory
                    Text(dir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(dir)
                        .onTapGesture {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
                        }
                }
            }

            Section {
                LabeledContent("LLM Status") {
                    if modelManager.llmReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if case .downloading = coordinator.state {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Not loaded", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("STT Status") {
                    if modelManager.sttReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not loaded", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var modelCacheDirectory: String {
        if modelManager.selectedModel.isLocal {
            return modelManager.selectedModel.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cache/huggingface/hub"
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        Form {
            KeyboardShortcuts.Recorder("Voice Edit:", name: .voiceEdit)
            KeyboardShortcuts.Recorder("Grammar Fix:", name: .grammarFix)
            KeyboardShortcuts.Recorder("Dictation:", name: .dictation)
        }
        .padding()
    }
}

/// Bridges into AppKit to force-activate the window for LSUIElement apps.
/// SwiftUI's .onAppear fires before the NSWindow exists, so we hook into
/// viewDidMoveToWindow() which fires at exactly the right time.
private struct WindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class ActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                // View removed from window — settings closed
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private struct HotkeyHintRow: View {
    let label: String
    let shortcutName: KeyboardShortcuts.Name

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
                Text(shortcut.description)
                    .font(.caption)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Not set")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
