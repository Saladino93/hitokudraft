import SwiftUI
import KeyboardShortcuts
import Sparkle

struct SettingsView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @ObservedObject var modelManager: ModelManager
    let updater: SPUUpdater?

    init(coordinator: ConversationCoordinator, updater: SPUUpdater? = nil) {
        self.coordinator = coordinator
        self.modelManager = coordinator.modelManager
        self.updater = updater
    }

    @AppStorage("maxRecordingDuration") private var maxRecordingDuration: Double = 30.0
    @AppStorage("silenceDurationLimit") private var silenceDurationLimit: Double = 2.0
    @AppStorage("activationSound")      private var activationSound: String = "Glass"
    @AppStorage("completionSound")      private var completionSound: String = "Glass"
    @AppStorage("appLanguage")           private var appLanguage: String = AppLocalization.detectInitialLanguage()

    // MARK: - Navigation State
    private enum Tab { case general, model, updates }
    @State private var selectedTab: Tab = .general

    // MARK: - Custom Model State
    @State private var customSourceType = CustomModelSourceType.huggingFace
    @State private var customModelPath = ""
    @State private var customValidation = CustomModelValidation.unchecked
    @State private var autoCheckUpdates: Bool = false

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

    // MARK: - Dynamic Window Height
    private var currentHeight: CGFloat {
        switch selectedTab {
        case .general: return 430
        case .model: return 400
        case .updates: return 125
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tag(Tab.general)
                .tabItem { Label(L("tab.general"), systemImage: "gear") }

            modelTab
                .tag(Tab.model)
                .tabItem { Label(L("tab.model"), systemImage: "cpu") }

            updatesTab
                .tag(Tab.updates)
                .tabItem { Label(L("tab.updates"), systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 620, height: currentHeight)
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: selectedTab)
        .background(WindowActivator())
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            // --- Language ---
            LabeledContent(L("language.label")) {
                Picker("", selection: $appLanguage) {
                    ForEach(AppLocalization.supportedLanguages, id: \.self) { code in
                        Text(AppLocalization.displayNames[code] ?? code).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            Spacer().frame(height: 12)

            // --- Permissions ---
            LabeledContent(L("permission.accessibility")) {
                permissionRow(granted: coordinator.permissions.accessibilityGranted) {
                    coordinator.permissions.requestAccessibility()
                }
            }

            Spacer().frame(height: 8)

            LabeledContent(L("permission.microphone")) {
                permissionRow(granted: coordinator.permissions.microphoneGranted) {
                    Task { await coordinator.permissions.requestMicrophone() }
                }
            }
            if !coordinator.permissions.allGranted {
                LabeledContent("") {
                    Text(L("permission.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 18)

            // --- Setup ---
            LabeledContent(L("models.label")) { setupStatusView }

            Spacer().frame(height: 18)

            // --- Shortcuts ---
            LabeledContent(L("shortcut.voice_edit")) { KeyboardShortcuts.Recorder("", name: .voiceEdit) }
            Spacer().frame(height: 4)
            LabeledContent(L("shortcut.grammar_fix")) { KeyboardShortcuts.Recorder("", name: .grammarFix) }
            Spacer().frame(height: 4)
            LabeledContent(L("shortcut.dictation")) { KeyboardShortcuts.Recorder("", name: .dictation) }

            Spacer().frame(height: 18)

            // --- Recording ---
            LabeledContent(L("recording.max_capture")) {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(L("recording.max_capture_unit", Int(maxRecordingDuration)), value: $maxRecordingDuration, in: 10...120, step: 5)
                    Text(L("recording.max_capture_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 8)

            LabeledContent(L("recording.silence_timeout")) {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(L("recording.silence_timeout_unit", silenceDurationLimit), value: $silenceDurationLimit, in: 1.0...5.0, step: 0.5)
                    Text(L("recording.silence_timeout_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 18)

            // --- Sounds ---
            LabeledContent(L("sound.activation")) { soundPicker(selection: $activationSound) }
            Spacer().frame(height: 4)
            LabeledContent(L("sound.completion")) { soundPicker(selection: $completionSound) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Model Tab

    private var modelTab: some View {
        VStack(spacing: 0) {
            Form {
                // --- Active Models ---
                Picker(L("model.active_llm"), selection: $modelManager.selectedModel) {
                    ForEach(ModelRegistry.availableModels) { model in
                        Button {} label: {
                            HStack(spacing: 4) {
                                Text(L(model.description))
                                if !ModelRegistry.isBundled(model) {
                                    Text("custom").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.blue.opacity(0.2)))
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text("\(model.name) (\(formattedSize(model.estimatedMemoryGB)))")
                        }
                        .tag(model)
                        .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                    }
                }

                if !ModelRegistry.isBundled(modelManager.selectedModel) {
                    LabeledContent("") {
                        Button(L("model.remove")) {
                            let toRemove = modelManager.selectedModel
                            modelManager.selectedModel = ModelRegistry.smartDefault
                            _ = ModelRegistry.removeModel(toRemove)
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                    }
                }

                Picker(L("model.active_stt"), selection: $modelManager.selectedSTTModel) {
                    ForEach(STTModelRegistry.availableModels) { model in
                        Button {} label: {
                            HStack(spacing: 4) {
                                if model.supportsNativeStreaming {
                                    Text("\(L(model.description)) (\(L("model.streaming")))")
                                } else {
                                    Text(L(model.description))
                                }
                                if let restriction = model.languageRestriction {
                                    Text(L(restriction))
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("\(model.name) (\(formattedSize(model.estimatedMemoryGB)))")
                        }
                        .tag(model)
                        .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                    }
                }

                Spacer().frame(height: 18)

                // --- Custom Model Loading ---
                LabeledContent(L("model.custom_source")) {
                    Picker("", selection: $customSourceType) {
                        ForEach(CustomModelSourceType.allCases, id: \.self) { source in
                            Text(L(source.rawValue)).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .onChange(of: customSourceType) { customValidation = .unchecked }
                }

                LabeledContent(L("model.model_path")) {
                    HStack {
                        TextField("", text: $customModelPath, prompt: Text(customSourceType == .local ? "/path/to/mlx-model" : "mlx-community/model-name"))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customModelPath) { validateCustomModel() }

                        ZStack {
                            Button(L("model.browse")) { browseForLocalModel() }
                                .opacity(customSourceType == .local ? 1 : 0)
                                .disabled(customSourceType != .local)
                        }
                    }
                }

                LabeledContent("") {
                    HStack {
                        Text(customSourceType == .local ? L("model.local_hint") : L("model.hf_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                        validationIndicator
                        Button(L("model.add")) { addCustomModel() }.disabled(!canAddCustomModel)
                    }
                }

                Spacer().frame(height: 18)

                // --- System Status ---
                LabeledContent(L("model.system_status")) {
                    HStack(spacing: 16) {
                        statusIndicator(label: "LLM", ready: modelManager.llmReady, loading: isLLMLoading)
                        statusIndicator(label: "STT", ready: modelManager.sttReady)
                    }
                }

                LabeledContent(L("model.cache_directory")) {
                    HStack {
                        Text(cacheDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(cacheDirectory)

                        Button(L("model.show_in_finder")) {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cacheDirectory)
                        }
                        .controlSize(.small)
                    }
                }
            }

            Spacer().frame(height: 36)

            Text(L("model.ai_warning"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.yellow)

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: modelManager.selectedModel) {
            UserDefaults.standard.set(modelManager.selectedModel.path, forKey: "selectedModelPath")
            Task { await coordinator.switchModel() }
        }
        .onChange(of: modelManager.selectedSTTModel) { Task { await coordinator.switchSTTModel() } }
    }

    // MARK: - Updates Tab

    private var updatesTab: some View {
        Form {
            if let updater {
                LabeledContent(L("updates.keep_updated")) {
                    Toggle(L("updates.auto_check"), isOn: $autoCheckUpdates)
                        .onAppear {
                            autoCheckUpdates = updater.automaticallyChecksForUpdates
                        }
                        .onChange(of: autoCheckUpdates) { newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }
                }

                Spacer().frame(height: 12)

                LabeledContent(L("updates.software_update")) {
                    Button(L("updates.check_now")) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            } else {
                LabeledContent(L("updates.software_update")) {
                    Text(L("updates.not_available"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Reusable UI Components

    private func permissionRow(granted: Bool, grant: @escaping () -> Void) -> some View {
        HStack {
            if granted {
                Label(L("permission.granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("permission.request_access"), action: grant)
            }
        }
    }

    private func soundPicker(selection: Binding<String>) -> some View {
        HStack {
            Picker("", selection: selection) {
                Text(L("sound.none")).tag("")
                Divider()
                ForEach(SoundPlayer.Sound.allCases, id: \.rawValue) { sound in
                    Text(sound.rawValue).tag(sound.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Button {
                if let sound = SoundPlayer.Sound(rawValue: selection.wrappedValue) {
                    SoundPlayer.shared.play(sound)
                }
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.plain)
            .disabled(selection.wrappedValue.isEmpty)
        }
    }

    @ViewBuilder
    private var setupStatusView: some View {
        switch coordinator.state {
        case .downloading:
            DownloadProgressView(progress: modelManager.llmProgress, statusMessage: modelManager.statusMessage)
        case .warmingUp:
            HStack {
                ProgressView().controlSize(.small)
                Text(L("models.warming_up"))
            }
        case .error(let msg):
            HStack(spacing: 6) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                Button(L("models.retry")) { Task { await coordinator.setup() } }
            }
        default:
            if modelManager.llmReady && modelManager.sttReady {
                Label(L("models.all_loaded"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if modelManager.llmReady {
                Label(L("models.llm_ready_stt_failed"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Button(L("models.download_setup")) { Task { await coordinator.setup() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func statusIndicator(label: String, ready: Bool, loading: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text("\(label):").foregroundStyle(.secondary)
            if ready {
                Label(L("model.status_ready"), systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
            } else if loading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(L("model.status_loading")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(L("model.status_not_loaded"), systemImage: "circle.fill").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var validationIndicator: some View {
        switch customValidation {
        case .unchecked: EmptyView()
        case .compatible: Label(L("model.compatible"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .needsConversion: Label(L("model.needs_conversion"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .unsupported(let reason): Label(reason, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Model Helpers

    private var physicalMemoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
    private func modelExceedsRAM(_ memGB: Double) -> Bool { memGB > 0 && memGB > physicalMemoryGB * 0.5 }

    private func formattedSize(_ gb: Double) -> String {
        if gb == 0 {
            return "unknown"
        } else if gb < 1.0 {
            return String(format: "%.0f MB", gb * 1024)
        } else {
            return String(format: "%.1f GB", gb)
        }
    }

    private var cacheDirectory: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("models").path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/models").path
    }

    private var isLLMLoading: Bool {
        if case .downloading = coordinator.state { return true }
        if case .warmingUp = coordinator.state { return true }
        return false
    }

    private var canAddCustomModel: Bool { customValidation == .compatible || customValidation == .needsConversion }

    private func validateCustomModel() {
        let path = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { customValidation = .unchecked; return }
        switch customSourceType {
        case .local:
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                customValidation = .unsupported(L("model.dir_not_found"))
                return
            }
            let configExists = FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("config.json").path)
            customValidation = configExists ? .compatible : .needsConversion
        case .huggingFace:
            if path.contains("/") && !path.hasPrefix("/") && !path.contains(" ") { customValidation = .compatible }
            else { customValidation = .unsupported(L("model.hf_format_hint")) }
        }
    }

    private func addCustomModel() {
        let path = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = customSourceType == .local ? URL(fileURLWithPath: path).lastPathComponent : (path.components(separatedBy: "/").last ?? path)
        let newModel = ModelOption(name: name, path: path)
        if ModelRegistry.addModel(newModel) {
            modelManager.selectedModel = newModel
        } else if let existing = ModelRegistry.availableModels.first(where: { $0.path == path }) {
            modelManager.selectedModel = existing
        }
        customModelPath = ""
        customValidation = .unchecked
    }

    private func browseForLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("model.local_hint")
        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
            validateCustomModel()
        }
    }
}

// MARK: - Window Activator

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
