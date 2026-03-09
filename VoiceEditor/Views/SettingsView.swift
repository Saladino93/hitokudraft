import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @ObservedObject var modelManager: ModelManager

    init(coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        self.modelManager = coordinator.modelManager
    }

    @AppStorage("maxRecordingDuration") private var maxRecordingDuration: Double = 30.0
    @AppStorage("activationSound")      private var activationSound: String = "Tink"
    @AppStorage("completionSound")      private var completionSound: String = "Pop"

    // MARK: - Custom Model State

    @State private var customSourceType = CustomModelSourceType.huggingFace
    @State private var customModelPath = ""
    @State private var customValidation = CustomModelValidation.unchecked

    private enum CustomModelSourceType: String, CaseIterable {
        case local = "Local Folder"
        case huggingFace = "Hugging Face"
    }

    private enum CustomModelValidation: Equatable {
        case unchecked
        case compatible
        case needsConversion
        case unsupported(String)
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
        }
        .frame(width: 680, height: 520)
        .fontDesign(.rounded)
        .background(WindowActivator())
    }

    // MARK: - General

    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                Divider()

                PrefRow(title: "Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow("Accessibility", granted: coordinator.permissions.accessibilityGranted) {
                            coordinator.permissions.requestAccessibility()
                        }
                        permissionRow("Microphone", granted: coordinator.permissions.microphoneGranted) {
                            Task { await coordinator.permissions.requestMicrophone() }
                        }
                        if !coordinator.permissions.allGranted {
                            Text("After clicking Grant, open System Settings › Privacy & Security.")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                PrefRow(title: "Models") {
                    setupStatusView
                }

                Divider()

                PrefRow(title: "Shortcuts") {
                    VStack(alignment: .leading, spacing: 10) {
                        shortcutRow("Voice Edit",  name: .voiceEdit)
                        shortcutRow("Grammar Fix", name: .grammarFix)
                        shortcutRow("Dictation",   name: .dictation)
                    }
                }

                Divider()

                PrefRow(title: "Recording") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Max capture")
                            Spacer()
                            Stepper("\(Int(maxRecordingDuration)) s",
                                    value: $maxRecordingDuration, in: 10...120, step: 5)
                        }
                        Text("Applies to Voice Edit and Grammar Fix. Dictation stops on silence.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                PrefRow(title: "Sounds") {
                    VStack(alignment: .leading, spacing: 10) {
                        soundRow("Activation", selection: $activationSound)
                        soundRow("Completion", selection: $completionSound)
                    }
                }

                Divider()
            }
        }
    }

    private func permissionRow(_ label: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant", action: grant)
            }
        }
    }

    private func shortcutRow(_ label: String, name: KeyboardShortcuts.Name) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            KeyboardShortcuts.Recorder("", name: name)
        }
    }

    private func soundRow(_ label: String, selection: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                Text("None").tag("")
                Divider()
                ForEach(SoundPlayer.Sound.allCases, id: \.rawValue) { sound in
                    Text(sound.rawValue).tag(sound.rawValue)
                }
            }
            .frame(width: 130)
            Button {
                if let sound = SoundPlayer.Sound(rawValue: selection.wrappedValue) {
                    SoundPlayer.shared.play(sound)
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(selection.wrappedValue.isEmpty)
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
                Text("Warming up\u{2026}")
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry") {
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
                Button("Download & Set Up") {
                    Task { await coordinator.setup() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Model

    private var modelTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                Divider()

                PrefRow(title: "Model") {
                    VStack(alignment: .leading, spacing: 12) {
                        if isCustomModelActive {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(modelManager.selectedModel.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use Built-in") {
                                    modelManager.selectedModel = ModelRegistry.defaultModel
                                    customModelPath = ""
                                    customValidation = .unchecked
                                }
                                .buttonStyle(.link)
                            }
                        } else {
                            Picker("", selection: $modelManager.selectedModel) {
                                ForEach(ModelRegistry.availableModels) { model in
                                    Button { } label: {
                                        Text(model.description)
                                        Text(model.name)
                                    }
                                    .tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                Divider()

                PrefRow(title: "Custom") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Source", selection: $customSourceType) {
                            ForEach(CustomModelSourceType.allCases, id: \.self) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: customSourceType) {
                            customValidation = .unchecked
                        }

                        HStack(spacing: 8) {
                            TextField(
                                customSourceType == .local
                                    ? "/path/to/mlx-model"
                                    : "org/model-name",
                                text: $customModelPath
                            )
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customModelPath) {
                                validateCustomModel()
                            }

                            if customSourceType == .local {
                                Button("Browse\u{2026}") {
                                    browseForLocalModel()
                                }
                                .controlSize(.small)
                                .font(.system(size: 13))
                            }
                        }

                        validationIndicator

                        Text("Local directory or HuggingFace repo (org/model-name).")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)

                        Button("Load Model") {
                            loadCustomModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canLoadCustomModel)
                    }
                }

                Divider()

                PrefRow(title: "Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("LLM")
                            Spacer()
                            statusIndicator(ready: modelManager.llmReady, loading: isLLMLoading)
                        }
                        HStack {
                            Text("STT")
                            Spacer()
                            statusIndicator(ready: modelManager.sttReady)
                        }
                    }
                }

                Divider()

                PrefRow(title: "Cache") {
                    Text(modelCacheDirectory)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(modelCacheDirectory)
                        .onTapGesture {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: modelCacheDirectory)
                        }
                }

                Divider()

                Text("AI models can make mistakes. Review outputs before use.")
                    .font(.system(size: 21))
                    .foregroundStyle(.yellow.opacity(0.75))
                    .padding(.horizontal, 24)
                    .padding(.top, 36)
                    .padding(.bottom, 16)
            }
        }
        .onChange(of: modelManager.selectedModel) {
            Task { await coordinator.switchModel() }
        }
    }

    // MARK: - Model Helpers

    private var modelCacheDirectory: String {
        if modelManager.selectedModel.isLocal {
            return modelManager.selectedModel.path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub").path
    }

    private var isCustomModelActive: Bool {
        !ModelRegistry.availableModels.contains(modelManager.selectedModel)
    }

    private var isLLMLoading: Bool {
        if case .downloading = coordinator.state { return true }
        if case .warmingUp = coordinator.state { return true }
        return false
    }

    @ViewBuilder
    private func statusIndicator(ready: Bool, loading: Bool = false) -> some View {
        if ready {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Ready").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        } else if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(.gray.opacity(0.4)).frame(width: 6, height: 6)
                Text("Not loaded").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var validationIndicator: some View {
        switch customValidation {
        case .unchecked:
            EmptyView()
        case .compatible:
            Label("Compatible", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .needsConversion:
            Label("May need conversion before use", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unsupported(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var canLoadCustomModel: Bool {
        customValidation == .compatible || customValidation == .needsConversion
    }

    private func validateCustomModel() {
        let path = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            customValidation = .unchecked
            return
        }
        switch customSourceType {
        case .local:
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else {
                customValidation = .unsupported("Directory not found")
                return
            }
            let configExists = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: path).appendingPathComponent("config.json").path
            )
            customValidation = configExists ? .compatible : .needsConversion
        case .huggingFace:
            if path.contains("/") && !path.hasPrefix("/") && !path.contains(" ") {
                customValidation = .compatible
            } else {
                customValidation = .unsupported("Use format: organization/model-name")
            }
        }
    }

    private func loadCustomModel() {
        let path = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if customSourceType == .local {
            name = URL(fileURLWithPath: path).lastPathComponent
        } else {
            name = path.components(separatedBy: "/").last ?? path
        }
        modelManager.selectedModel = ModelOption(name: name, path: path)
    }

    private func browseForLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select an MLX model directory"
        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
            validateCustomModel()
        }
    }
}

private struct PrefRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .padding(.top, 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 19))
        }
        .padding(.leading, 24)
        .padding(.trailing, 44)
        .padding(.vertical, 18)
    }
}

#Preview {
    SettingsView(coordinator: ConversationCoordinator())
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
                ActivationPolicyManager.shared.trackWindow(window)
                window.standardWindowButton(.closeButton)?.keyEquivalent = "\u{1B}"
                window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = []
            }
        }
    }
}
