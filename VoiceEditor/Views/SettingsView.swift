import FluidAudio
import KeyboardShortcuts
import Sparkle
import SwiftUI

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
    @AppStorage("silenceDurationLimit") private var silenceDurationLimit: Double = 1.5
    @AppStorage("noSpeechTimeout")      private var noSpeechTimeout: Double = 3.5
    @AppStorage("activationSound")      private var activationSound: String = "Tink"
    @AppStorage("completionSound")      private var completionSound: String = "Pop"
    @AppStorage("appLanguage")           private var appLanguage: String = AppLocalization.detectInitialLanguage()
    @AppStorage("contextAwareMode")      private var contextAwareMode: String = "off"
    @AppStorage("visionEnabled")          private var visionEnabled: Bool = false
    @AppStorage("showDictationText")          private var showDictationText: Bool = true
    @AppStorage("showLLMStreamingInOverlay")  private var showLLMStreamingInOverlay: Bool = true
    @AppStorage("dictationTheme")        private var dictationTheme: String = DictationTheme.default.rawValue
    @AppStorage("overlayLineCount")      private var overlayLineCount: Int = 2
    @AppStorage("overlayWidth")          private var overlayWidth: Double = 210
    @AppStorage("ttsEnabled")            private var ttsEnabled: Bool = false
    @AppStorage("ttsBackend")            private var ttsBackend: String = "kokoro"
    @AppStorage("ttsVoice")              private var ttsVoice: String = TtsConstants.recommendedVoice
    @AppStorage("ttsSpeed")              private var ttsSpeed: Double = 1.0
    @AppStorage("internetAccessEnabled") private var internetAccessEnabled: Bool = false

    // MARK: - Navigation State
    private enum Tab { case license, general, tools, appearance, model, updates }
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
        case .general: return 510
        case .tools: return 340
        case .appearance: return 473
        case .model: return ttsEnabled ? 518 : 423
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

            toolsTab
                .tag(Tab.tools)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            appearanceTab
                .padding(.top, 20)
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
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: ttsEnabled)
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
                    .padding(.leading, -6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
            }
            Color.clear.frame(height: 4)
            GridRow {
                Text(L("shortcut.grammar_fix"))
                KeyboardShortcuts.Recorder("", name: .grammarFix)
                    .padding(.leading, -6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
            }
            Color.clear.frame(height: 4)
            GridRow {
                Text(L("shortcut.dictation"))
                KeyboardShortcuts.Recorder("", name: .dictation)
                    .padding(.leading, -6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
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

            Color.clear.frame(height: 18)

            // Internet access moved to Tools tab
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
                    HStack(spacing: 8) {
                        Toggle("", isOn: $showDictationText)
                            .labelsHidden()
                        Text(L("recording.show_dictation_text_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .gridColumnAlignment(.leading)
                }

                Color.clear.frame(height: 6)

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

                Color.clear.frame(height: 14)

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

                Color.clear.frame(height: 14)

                GridRow {
                    Text(L("overlay.width"))
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Slider(value: $overlayWidth, in: 150...400, step: 10)
                                .frame(maxWidth: 210)
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
                .padding(.top, -4)

            // Theme picker section
            VStack(alignment: .leading, spacing: 4) {
                Text(L("theme.panel_style"))
                    .font(.headline)
                Text(L("theme.panel_style_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, -20)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                ForEach(DictationTheme.allCases) { theme in
                    let isSelected = dictationTheme == theme.rawValue
                    VStack(spacing: 6) {
                        themePreview(theme: theme)
                        Text(theme.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? theme.accentColor.opacity(0.10) : .white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? theme.accentColor.opacity(0.4) : .white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { dictationTheme = theme.rawValue }
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

    // MARK: - Tools Tab

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Transcription history (top)
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription History")
                        .font(.subheadline.weight(.medium))
                    Text("All voice interactions are saved as JSON files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") {
                    Task {
                        let path = await TranscriptionStore.shared.directoryPath
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                }
                .font(.caption)
            }

            Divider()

            // Internet toggle
            HStack(spacing: 8) {
                Toggle("", isOn: $internetAccessEnabled)
                    .labelsHidden()
                Text("Allow internet access")
                    .font(.subheadline)
                Text("(web search, URL fetch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Available tools — compact 2-column grid
            Text("Available Tools")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 8) {
                toolCell(icon: "magnifyingglass", name: "Web Search", subtitle: "DuckDuckGo", internet: true)
                toolCell(icon: "globe", name: "URL Fetch", subtitle: "Read web pages", internet: true)
                toolCell(icon: "calendar", name: "Calendar", subtitle: "Events & free time", internet: false)
                toolCell(icon: "timer", name: "Timer", subtitle: "Countdown alerts", internet: false)
                toolCell(icon: "note.text", name: "Notes", subtitle: "Apple Notes", internet: false)
                toolCell(icon: "envelope", name: "Email", subtitle: "Compose window", internet: false)
                toolCell(icon: "macwindow", name: "Launch App", subtitle: "Open by name", internet: false)
            }
        }
        .padding(20)
    }

    private func toolCell(icon: String, name: String, subtitle: String, internet: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(internet && !internetAccessEnabled ? .quaternary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if internet {
                        Circle()
                            .fill(internetAccessEnabled ? .green : .gray.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06)))
        .opacity(internet && !internetAccessEnabled ? 0.5 : 1.0)
    }

    // MARK: - Model Tab

    private var modelTab: some View {
        VStack(spacing: 0) {
            Grid(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline),
                 horizontalSpacing: 12, verticalSpacing: 0) {

                // ---- Active Models ----
                GridRow {
                    Text(L("model.active_llm"))
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $modelManager.selectedModel) {
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
                                Text(model.estimatedMemoryGB > 0
                                     ? "\(model.name) (\(formattedSize(model.estimatedMemoryGB)))"
                                     : model.name)
                            }
                            .tag(model)
                            .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .gridColumnAlignment(.leading)
                }

                if !ModelRegistry.isBundled(modelManager.selectedModel) {
                    Color.clear.frame(height: 4)
                    GridRow {
                        Text("")
                        Button(L("model.remove")) {
                            let toRemove = modelManager.selectedModel
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

                if coordinator.modelManager.selectedModel.isVLM {
                    Color.clear.frame(height: 4)
                    GridRow {
                        Text("")
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Allow vision (sees screenshots, slower)", isOn: $visionEnabled)
                                .toggleStyle(.checkbox)
                                .onChange(of: visionEnabled) {
                                    coordinator.modelManager.loadedModelPath = nil
                                    Task { try? await coordinator.modelManager.reloadLLM() }
                                }
                        }
                    }
                }

                Color.clear.frame(height: 8)

                GridRow {
                    Text(L("model.active_stt"))
                    Picker("", selection: $modelManager.selectedSTTModel) {
                        ForEach(STTModelRegistry.availableModels) { model in
                            Button {} label: {
                                Text(L(model.description))
                                Text(model.estimatedMemoryGB > 0
                                     ? "\(model.name) (\(formattedSize(model.estimatedMemoryGB)))"
                                     : model.name)
                            }
                            .tag(model)
                            .disabled(modelExceedsRAM(model.estimatedMemoryGB))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                Color.clear.frame(height: 18)

                // ---- Auto-offload ----
                GridRow {
                    Text(L("model.auto_offload"))
                    HStack(spacing: 10) {
                        Toggle("", isOn: $modelManager.autoOffloadEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: modelManager.autoOffloadEnabled) {
                                UserDefaults.standard.set(modelManager.autoOffloadEnabled, forKey: "modelAutoOffload")
                                if modelManager.autoOffloadEnabled { modelManager.keepAlive() }
                                else { modelManager.cancelOffload() }
                            }
                        Text(L("model.auto_offload_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Color.clear.frame(height: 18)

                // ---- Polish dictation ----
                GridRow {
                    Text(L("model.polish_dictation"))
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "polishDictation") },
                            set: { UserDefaults.standard.set($0, forKey: "polishDictation") }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        Text(L("model.polish_dictation_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Color.clear.frame(height: 18)

                // ---- Custom Model ----
                GridRow {
                    Text(L("model.custom_source"))
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

                Color.clear.frame(height: 6)

                GridRow {
                    Text(L("model.model_path"))
                    HStack {
                        TextField("", text: $customModelPath,
                                  prompt: Text(customSourceType == .local ? "/path/to/mlx-model" : "mlx-community/model-name"))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customModelPath) { validateCustomModel() }
                        if customSourceType == .local {
                            Button(L("model.browse")) { browseForLocalModel() }
                        }
                        Button(L("model.add")) { addCustomModel() }
                            .disabled(!canAddCustomModel)
                    }
                }

                GridRow {
                    Text("")
                    HStack {
                        Text(customSourceType == .local ? L("model.local_hint") : L("model.hf_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        validationIndicator
                    }
                }

                Color.clear.frame(height: 18)

                // ---- Voice Readback (TTS) ----
                GridRow {
                    Text(L("tts.label"))
                    HStack(spacing: 10) {
                        Toggle("", isOn: $ttsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text(L("tts.enable_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if ttsEnabled {
                    Color.clear.frame(height: 6)

                    GridRow {
                        Text(L("tts.backend"))
                        Picker("", selection: $ttsBackend) {
                            Text("Kokoro").tag("kokoro")
                            Text("PocketTTS").tag("pocketTts")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .onChange(of: ttsBackend) {
                            // Reset voice to the new backend's default female voice.
                            ttsVoice = ttsBackend == "pocketTts"
                                ? PocketTTSProvider.defaultVoice
                                : KokoroTTSProvider.defaultVoice
                        }
                    }

                    Color.clear.frame(height: 6)

                    GridRow {
                        Text(L("tts.voice"))
                        Picker("", selection: $ttsVoice) {
                            ForEach(ttsVoicesForBackend, id: \.self) { voice in
                                Text(ttsVoiceDisplayName(voice)).tag(voice)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }

                    Color.clear.frame(height: 6)

                    GridRow {
                        Text(L("tts.speed"))
                        HStack(spacing: 8) {
                            Stepper(
                                String(format: L("tts.speed_unit"), ttsSpeed),
                                value: $ttsSpeed,
                                in: 0.5...2.0,
                                step: 0.25
                            )
                            .disabled(ttsBackend == "pocketTts")
                        }
                    }
                }

                Color.clear.frame(height: 18)

                // ---- System Status ----
                GridRow {
                    Text(L("model.system_status"))
                    HStack(spacing: 16) {
                        statusIndicator(label: "LLM", ready: modelManager.llmReady, loading: isLLMLoading, disabled: modelManager.llmDisabled)
                        statusIndicator(label: "STT", ready: modelManager.sttReady)
                        statusIndicator(label: "TTS", ready: ttsEnabled, disabled: !ttsEnabled)
                    }
                }

                Color.clear.frame(height: 6)

                GridRow {
                    Text(L("model.cache_directory"))
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
            .frame(maxWidth: .infinity, alignment: .leading)

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

    // MARK: - TTS Helpers

    private var ttsVoicesForBackend: [String] {
        if ttsBackend == "pocketTts" {
            return PocketTTSProvider.femaleVoices
        }
        return KokoroTTSProvider.femaleVoices
    }

    private func ttsVoiceDisplayName(_ voice: String) -> String {
        guard voice.count >= 3, voice[voice.index(voice.startIndex, offsetBy: 2)] == "_" else {
            // PocketTTS voices: no language prefix, may have underscores (e.g. "caro_davy" → "Caro Davy").
            let spaced = voice.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
        let chars = Array(voice)
        let langCode = String(chars[0])
        let namePart = String(voice.dropFirst(3))
        let displayName = namePart.prefix(1).uppercased() + namePart.dropFirst()
        let tag: String = switch langCode {
        case "a": "US"
        case "b": "UK"
        case "e": "ES"
        case "f": "FR"
        case "h": "HI"
        case "i": "IT"
        case "j": "JA"
        case "p": "PT"
        case "z": "ZH"
        default:  langCode.uppercased()
        }
        return "\(displayName) (\(tag))"
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
