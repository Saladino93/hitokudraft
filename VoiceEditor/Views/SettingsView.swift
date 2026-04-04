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
    @AppStorage("silenceDurationLimit") private var silenceDurationLimit: Double = 0.5
    @AppStorage("noSpeechTimeout")      private var noSpeechTimeout: Double = 3.0
    @AppStorage("activationSound")      private var activationSound: String = "Glass"
    @AppStorage("completionSound")      private var completionSound: String = "Glass"
    @AppStorage("appLanguage")           private var appLanguage: String = AppLocalization.detectInitialLanguage()
    @AppStorage("contextAwareMode")      private var contextAwareMode: String = "off"
    @AppStorage("showDictationText")          private var showDictationText: Bool = true
    @AppStorage("showLLMStreamingInOverlay")  private var showLLMStreamingInOverlay: Bool = true
    @AppStorage("dictationTheme")        private var dictationTheme: String = DictationTheme.default.rawValue
    @AppStorage("overlayLineCount")      private var overlayLineCount: Int = 2
    @AppStorage("overlayWidth")          private var overlayWidth: Double = 210

    // MARK: - Navigation State
    private enum Tab { case license, general, appearance, model, updates }
    @State private var selectedTab: Tab = .general

    // MARK: - Custom Model State
    @State private var customSourceType = CustomModelSourceType.huggingFace
    @State private var customModelPath = ""
    @State private var customValidation = CustomModelValidation.unchecked
    @State private var autoCheckUpdates: Bool = false
    @State private var hoveredTheme: DictationTheme?
    @State private var cacheSizeText: String?

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
        case .license: return 178
        case .general: return 518
        case .appearance: return 430
        case .model: return 395
        case .updates: return 122
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

            appearanceTab
                .tag(Tab.appearance)
                .tabItem { Label(L("tab.theme"), systemImage: "paintbrush") }

            LicenseActivationView(licenseManager: coordinator.licenseManager)
                .tag(Tab.license)
                .tabItem { Label(L("tab.license"), systemImage: "key") }

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
        Grid(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline), horizontalSpacing: 12, verticalSpacing: 0) {
            // --- Language ---
            GridRow {
                Text(L("language.label"))
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $appLanguage) {
                    ForEach(AppLocalization.supportedLanguages, id: \.self) { code in
                        Text(AppLocalization.displayNames[code] ?? code).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .gridColumnAlignment(.leading)
            }

            Color.clear.frame(height: 12)

            // --- Permissions ---
            GridRow {
                Text(L("permission.accessibility"))
                permissionRow(granted: coordinator.permissions.accessibilityGranted) {
                    coordinator.permissions.requestAccessibility()
                }
            }

            Color.clear.frame(height: 8)

            GridRow {
                Text(L("permission.microphone"))
                permissionRow(granted: coordinator.permissions.microphoneGranted) {
                    Task { await coordinator.permissions.requestMicrophone() }
                }
            }

            Color.clear.frame(height: 8)

            // --- Context Awareness ---
            GridRow {
                Text(L("context.label"))
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $contextAwareMode) {
                        Text(L("context.off")).tag("off")
                        Text(L("context.standard")).tag("standard")
                        Text(L("context.advanced")).tag("advanced")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .onChange(of: contextAwareMode) { _, newValue in
                        if newValue != "off" && !coordinator.permissions.screenRecordingGranted {
                            coordinator.permissions.requestScreenRecording()
                        }
                    }

                    Text(L("context.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Color.clear.frame(height: 8)

            GridRow {
                Text(L("permission.screen_recording"))
                permissionRow(granted: coordinator.permissions.screenRecordingGranted) {
                    coordinator.permissions.requestScreenRecording()
                }
            }

            if !coordinator.permissions.allGranted {
                GridRow {
                    Text("")
                    Text(L("permission.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Color.clear.frame(height: 18)

            // --- Setup status row (disabled — re-enable if needed) ---
            // GridRow {
            //     Text(L("models.label"))
            //     setupStatusView
            // }
            // Color.clear.frame(height: 18)

            // --- Shortcuts ---
            GridRow {
                Text(L("shortcut.voice_edit"))
                KeyboardShortcuts.Recorder("", name: .voiceEdit)
            }
            Color.clear.frame(height: 4)
            GridRow {
                Text(L("shortcut.grammar_fix"))
                KeyboardShortcuts.Recorder("", name: .grammarFix)
            }
            Color.clear.frame(height: 4)
            GridRow {
                Text(L("shortcut.dictation"))
                KeyboardShortcuts.Recorder("", name: .dictation)
            }

            Color.clear.frame(height: 18)

            // --- Recording ---
            GridRow {
                Text(L("recording.max_capture"))
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(L("recording.max_capture_unit", Int(maxRecordingDuration)), value: $maxRecordingDuration, in: 10...120, step: 5)
                    Text(L("recording.max_capture_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Color.clear.frame(height: 8)

            GridRow {
                Text(L("recording.silence_timeout"))
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(L("recording.silence_timeout_unit", silenceDurationLimit), value: $silenceDurationLimit, in: 0.5...3.0, step: 0.5)
                    Text(L("recording.silence_timeout_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Color.clear.frame(height: 8)

            GridRow {
                Text(L("recording.no_speech_timeout"))
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(L("recording.no_speech_timeout_unit", Int(noSpeechTimeout)), value: $noSpeechTimeout, in: 2...8, step: 1)
                    Text(L("recording.no_speech_timeout_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Color.clear.frame(height: 18)

            // --- Sounds ---
            GridRow {
                Text(L("sound.activation"))
                soundPicker(selection: $activationSound)
            }
            Color.clear.frame(height: 4)
            GridRow {
                Text(L("sound.completion"))
                soundPicker(selection: $completionSound)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Toggle for showing dictation text
            Grid(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline), horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text(L("recording.show_dictation_text"))
                        .gridColumnAlignment(.trailing)
                    Toggle("", isOn: $showDictationText)
                        .labelsHidden()
                        .gridColumnAlignment(.leading)
                }

                GridRow {
                    Text(L("overlay.show_llm_streaming"))
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        Toggle("", isOn: $showLLMStreamingInOverlay)
                            .labelsHidden()
                        Text(L("overlay.show_llm_streaming_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .gridColumnAlignment(.leading)
                }

                Color.clear.frame(height: 8)

                GridRow {
                    Text(L("overlay.line_count"))
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $overlayLineCount) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        Text(L("overlay.line_count_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .gridColumnAlignment(.leading)
                }

                Color.clear.frame(height: 8)

                GridRow {
                    Text(L("overlay.width"))
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Slider(value: $overlayWidth, in: 150...400, step: 10)
                                .frame(maxWidth: 200)
                            Text("\(Int(overlayWidth)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        Text(L("overlay.width_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .gridColumnAlignment(.leading)
                }
            }

            Divider()

            // Theme picker section
            VStack(alignment: .leading, spacing: 4) {
                Text(L("theme.panel_style"))
                    .font(.headline)
                Text(L("theme.panel_style_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(DictationTheme.allCases) { theme in
                    let isSelected = dictationTheme == theme.rawValue
                    let isHovered = hoveredTheme == theme

                    HStack(spacing: 14) {
                        // Mini preview capsule
                        themePreview(theme: theme)

                        // Name + description
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(theme.displayDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Radio checkmark
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isSelected ? theme.accent : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? theme.accent.opacity(0.08) : (isHovered ? .white.opacity(0.03) : .clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? theme.accent.opacity(0.3) : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dictationTheme = theme.rawValue
                    }
                    .onHover { hovering in
                        hoveredTheme = hovering ? theme : nil
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Static mini-preview of a theme's capsule with 5 bars.
    private func themePreview(theme: DictationTheme) -> some View {
        HStack(spacing: 2) {
            ForEach([0.35, 0.55, 0.75, 0.55, 0.35], id: \.self) { h in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 2, height: 12 * h)
            }
        }
        .frame(width: 24, height: 16)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.panelBackground)
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.panelBorder, lineWidth: 0.5)
        )
        .scaleEffect(0.85)
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
                                Text(model.description.isEmpty ? model.name : L(model.description))
                                if !ModelRegistry.isBundled(model) {
                                    Text("custom").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.blue.opacity(0.2)))
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(model.estimatedMemoryGB > 0 ? "\(model.name) (\(formattedSize(model.estimatedMemoryGB)))" : model.name)
                        }
                        .tag(model)
                        .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                    }
                }

                if !ModelRegistry.isBundled(modelManager.selectedModel) {
                    LabeledContent("") {
                        Button(L("model.remove")) {
                            let toRemove = modelManager.selectedModel
                            // Restore the previously-used model to avoid unnecessary downloads
                            if let prevPath = modelManager.previousModelPath,
                               prevPath != toRemove.path,
                               let prev = ModelRegistry.availableModels.first(where: { $0.path == prevPath }) {
                                modelManager.selectedModel = prev
                            } else {
                                modelManager.selectedModel = ModelRegistry.smartDefault
                            }
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
                            Text(model.estimatedMemoryGB > 0 ? "\(model.name) (\(formattedSize(model.estimatedMemoryGB)))" : model.name)
                        }
                        .tag(model)
                        .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                    }
                }

                Spacer().frame(height: 18)

                // --- Auto-offload ---
                LabeledContent(L("model.auto_offload")) {
                    Toggle("", isOn: $modelManager.autoOffloadEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: modelManager.autoOffloadEnabled) {
                            UserDefaults.standard.set(modelManager.autoOffloadEnabled, forKey: "modelAutoOffload")
                            if modelManager.autoOffloadEnabled {
                                modelManager.keepAlive()
                            } else {
                                modelManager.cancelOffload()
                            }
                        }
                }
                LabeledContent("") {
                    Text(L("model.auto_offload_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        statusIndicator(label: "LLM", ready: modelManager.llmReady, loading: isLLMLoading, disabled: modelManager.llmDisabled)
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

                        if let cacheSizeText {
                            Text(cacheSizeText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

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
        .task { cacheSizeText = await calculateCacheSizeText() }
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
                        .onChange(of: autoCheckUpdates) { _, newValue in
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
            let llmOk = modelManager.llmReady || modelManager.llmDisabled
            if llmOk && modelManager.sttReady {
                Label(L("models.all_loaded"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if llmOk && modelManager.sttLoading {
                Label(L("download.loading_stt"), systemImage: "arrow.down.circle").foregroundStyle(.blue)
            } else if llmOk {
                Label(L("models.llm_ready_stt_failed"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Button(L("models.download_setup")) { Task { await coordinator.setup() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func statusIndicator(label: String, ready: Bool, loading: Bool = false, disabled: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text("\(label):").foregroundStyle(.secondary)
            if disabled {
                Label(L("status.llm_disabled"), systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
            } else if ready {
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

    // showSetupStatus removed — Models row is now always visible.
    // setupStatusView already handles idle/loading/loaded/error states.

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
        let name = customSourceType == .local
            ? URL(fileURLWithPath: path).lastPathComponent
            : (path.components(separatedBy: "/").last ?? path)

        // Already in registry — just select it
        if let existing = ModelRegistry.availableModels.first(where: { $0.path == path }) {
            modelManager.selectedModel = existing
            customModelPath = ""
            customValidation = .unchecked
            return
        }

        let newModel = ModelOption.autoConfigured(name: name, path: path)

        if customSourceType == .local {
            // Local models: files already on disk — add to registry immediately
            var measured = newModel
            let size = ModelRegistry.measureModelOnDisk(newModel)
            if size > 0 { measured.estimatedMemoryGB = size }
            ModelRegistry.addModel(measured)
            modelManager.selectedModel = measured
        } else {
            // HuggingFace models: download first, add to registry only after success
            Task { await coordinator.downloadAndAddCustomModel(newModel) }
        }

        customModelPath = ""
        customValidation = .unchecked
    }

    private func calculateCacheSizeText() async -> String {
        calculateCacheSizeSync()
    }

    private nonisolated func calculateCacheSizeSync() -> String {
        let fm = FileManager.default
        guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return "" }
        let modelsDir = cachesURL.appendingPathComponent("models")
        guard let enumerator = fm.enumerator(
            at: modelsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            totalBytes += Int64(size)
        }

        let gb = Double(totalBytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "(%.1f GB)", gb)
        } else {
            let mb = Double(totalBytes) / 1_048_576
            return String(format: "(%.0f MB)", mb)
        }
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
