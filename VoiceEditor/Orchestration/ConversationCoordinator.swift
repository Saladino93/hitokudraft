import AVFoundation
import Combine
import UserNotifications
import FluidAudio
import MLXAudioSTT
import MLXLMCommon
import os
import SwiftUI

@MainActor
final class ConversationCoordinator: ObservableObject {
    private static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")
    @Published private(set) var state: AppState = .idle

    let permissions = PermissionsCoordinator()
    let modelManager = ModelManager()
    let licenseManager = LicenseManager()

    private let textCapture = TextCaptureService()
    private let audioCapture = AudioCaptureService()
    private let contextCapture = ContextCaptureService()
    private let editabilityDetector: any EditabilityDetector

    /// Non-empty when the last result was displayed in the overlay instead of pasted
    /// (focused element was not editable). Auto-cleared after 20 seconds.
    @Published private(set) var displayModeResult: String = ""
    private var stt: (any STTService)?
    private var llm: (any LLMService)?
    private var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var dictationSession: AudioCaptureService.ContinuousSession?
    private var streamingTask: Task<Void, Never>?
    private var voiceEditTask: Task<Void, Never>?
    private let dictationOverlay = DictationOverlayPanel()
    /// Action Mode module. Setting this to nil (or deleting Actions/) fully disables the feature.
    private var actionCoordinator: ActionCoordinator?

    /// Live transcription text for the overlay (updated during streaming; empty = show status label).
    @Published private(set) var liveTranscriptionText: String = ""
    /// Accumulating LLM output shown in the overlay during generation; cleared before paste.
    @Published private(set) var streamingLLMText: String = ""
    /// The active recording session — non-nil while the mic is recording.
    /// DictationOverlayPanel subscribes to this to start/stop level polling.
    @Published private(set) var activeRecordingSession: AudioCaptureService.ContinuousSession?

    @Published private(set) var contextAwareMode: ContextAwareMode = {
        let raw = UserDefaults.standard.string(forKey: "contextAwareMode") ?? "off"
        return ContextAwareMode(rawValue: raw) ?? .off
    }()

    /// When true, raw dictation transcripts are passed through a lightweight LLM pass
    /// that removes filler words and adds punctuation — without changing actual words.
    /// Only takes effect when an LLM is loaded (not the None sentinel).
    @Published private(set) var polishDictation: Bool =
        UserDefaults.standard.bool(forKey: "polishDictation")
    /// Last finalized text from a native streaming session (Qwen3-ASR).
    /// Set by `runStreamingTranscription` for `stopDictation()` to use.
    private var lastStreamingTranscription: String?

    /// Stores the last successful voice-edit result for follow-up commands.
    private struct EditContext {
        let instruction: String
        let result: String
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 300 }
    }
    private var lastEditContext: EditContext?

    /// Cancellable model-loading tasks so a new switch can abort an in-flight download.
    private var llmLoadTask: Task<Void, Never>?
    private var sttLoadTask: Task<Void, Never>?
    /// Scheduled auto-clear for display-mode results; cancelled early by clearDisplayModeResult().
    private var displayModeClearTask: Task<Void, Never>?

    /// Pending model switches that couldn't run because state wasn't idle.
    private var pendingLLMSwitch = false
    private var pendingSTTSwitch = false

    var menuBarIcon: Image {
        switch state {
        case .listening: return Image(systemName: "mic.fill")
        case .transcribing: return Image(systemName: "waveform")
        case .generating: return Image(systemName: "brain")
        case .pasting: return Image(systemName: "doc.on.clipboard")
        case .dictating: return Image(systemName: "mic.badge.plus")
        case .error: return Image(systemName: "exclamationmark.triangle")
        case .downloading: return Image(systemName: "arrow.down.circle")
        case .warmingUp: return Image(systemName: "gear")
        case .idle: return Image("hitoku-icon-template") //Image(systemName: "text.bubble")
        }
    }

    init(editabilityDetector: any EditabilityDetector = AXEditabilityDetector()) {
        self.editabilityDetector = editabilityDetector
        // Forward child ObservableObject changes so SwiftUI re-renders
        permissions.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        modelManager.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        licenseManager.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Re-try hotkey registration when accessibility is granted later
        permissions.onAccessibilityGranted = { [weak self] in
            self?.setupHotkeys()
        }

        // Rebuild LLM service when context awareness mode changes (updates system prompt)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let raw = UserDefaults.standard.string(forKey: "contextAwareMode") ?? "off"
                let newMode = ContextAwareMode(rawValue: raw) ?? .off
                if newMode != self.contextAwareMode {
                    self.contextAwareMode = newMode
                    self.rebuildLLMServiceIfNeeded()
                }
                let polish = UserDefaults.standard.bool(forKey: "polishDictation")
                if polish != self.polishDictation { self.polishDictation = polish }
            }
            .store(in: &cancellables)

        // When memory offload clears models, nil out the service objects this coordinator holds
        modelManager.$sttReady
            .sink { [weak self] ready in if !ready { self?.stt = nil } }
            .store(in: &cancellables)
        modelManager.$llmReady
            .sink { [weak self] ready in if !ready { self?.llm = nil } }
            .store(in: &cancellables)

        // Overlay observes published state instead of being commanded directly
        dictationOverlay.observe(self)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.setup() }
        }
    }

    // MARK: - Setup

    func setup() async {
        guard state == .idle else { return }
        state = .downloading(progress: 0)

        // Phase 0: LLM — start loading in background so STT/VAD setup can run in parallel.
        // The llmLoadTask will set llmReady = true and state = .idle when done.
        if llm == nil && !modelManager.selectedModel.isNone {
            llmLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.activateLLM(self.modelManager.selectedModel, drainAfter: false)
            }
        }

        // Phase 1: STT — always runs (independent of LLM choice)
        if stt == nil {
            modelManager.sttLoading = true
            do {
                try await modelManager.reloadSTT()
                stt = try await makeSttService()
                modelManager.sttReady = (stt != nil)
            } catch {
                // STT failure is non-fatal — log but don't block
                Self.log.error("STT setup failed: \(error.localizedDescription, privacy: .public)")
            }
            modelManager.sttLoading = false
        }

        // Phase 3: VAD — load Silero VAD for neural silence detection
        if modelManager.vadDetector == nil {
            do {
                modelManager.vadDetector = try await VoiceActivityDetector.create()
                Self.log.info("VAD loaded successfully")
            } catch {
                // VAD failure is non-fatal — falls back to RMS silence detection
                Self.log.warning("VAD init failed (RMS fallback): \(error.localizedDescription, privacy: .public)")
            }
        }

        setupHotkeys()

        // Wire Action Mode — remove these lines + the Actions/ folder to fully disable.
        actionCoordinator = ActionCoordinator(
            audioCapture: audioCapture,
            getSTT: { [weak self] in self?.stt },
            getLLM: { [weak self] in self?.llm },
            getVADDetector: { [weak self] in self?.modelManager.vadDetector }
        )
        actionCoordinator?.onStateChange = { [weak self] newState in
            self?.state = newState
            if case .error = newState { self?.resetErrorAfterDelay() }
        }
        actionCoordinator?.setLiveTranscript = { [weak self] text in self?.liveTranscriptionText = text }

        modelManager.statusMessage = ""
        state = .idle
        await drainPendingSwitches()

        // Pre-request notification permission so the system dialog appears at a predictable
        // time (app launch), not buried inside an action pipeline where LSUIElement apps
        // may not reliably surface the prompt.
        Task.detached(priority: .background) {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }

        // License: silent re-verify + first-launch prompt
        await licenseManager.reVerifyIfNeeded()
        if !licenseManager.isActivated {
            LicenseWindowController.show(licenseManager: licenseManager)
        }
    }

    func setupHotkeys() {
        guard permissions.accessibilityGranted, hotkeyManager == nil else { return }
        hotkeyManager = HotkeyManager(coordinator: self)
    }

    // MARK: - LLM Activation (shared loading pattern)

    /// Loads, initializes, and warms up an LLM. Updates state throughout.
    ///
    /// - Parameters:
    ///   - model: The model to load.
    ///   - drainAfter: Whether to call `drainPendingSwitches()` after completion.
    ///   - afterLoad: Optional work performed after load succeeds but before service creation
    ///                (used by `downloadAndAddCustomModel` to register the model).
    private func activateLLM(
        _ model: ModelOption,
        drainAfter: Bool = false,
        afterLoad: (() async -> Void)? = nil
    ) async {
        // None sentinel: release any loaded model weights, clear service
        guard !model.isNone else {
            try? await modelManager.loadModel(model)  // clears modelContainer + llmReady + GPU cache
            llm = nil
            state = .idle
            llmLoadTask = nil
            if drainAfter { await drainPendingSwitches() }
            return
        }

        do {
            try await modelManager.loadModel(model)
            try Task.checkCancellation()
            await afterLoad?()
            if let container = modelManager.modelContainer {
                llm = makeLLMService(container: container)
            }
            state = .warmingUp
            try await llm?.warmup()
            try Task.checkCancellation()
            modelManager.keepAlive()
            state = .idle
            SoundPlayer.shared.play(.glass)
        } catch is CancellationError {
            state = .idle
        } catch let error as URLError where error.code == .cancelled {
            state = .idle
        } catch {
            revertToLastLoadedModel()
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
        llmLoadTask = nil
        if drainAfter { await drainPendingSwitches() }
    }

    // MARK: - Model Switching

    /// Reverts the model picker to the last successfully-loaded model.
    /// No-op if no model has been loaded yet (e.g. first launch failure).
    private func revertToLastLoadedModel() {
        if let path = modelManager.loadedModelPath,
           let model = ModelRegistry.availableModels.first(where: { $0.path == path }) {
            modelManager.selectedModel = model
        }
    }

    func switchModel() async {
        // Cancel any in-flight LLM download/load
        if let existing = llmLoadTask {
            existing.cancel()
            await existing.value
            llmLoadTask = nil
        }

        guard state == .idle else {
            Self.log.warning("switchModel deferred — state is \(String(describing: self.state))")
            pendingLLMSwitch = true
            return
        }

        pendingLLMSwitch = false
        state = .downloading(progress: 0)

        llmLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.activateLLM(self.modelManager.selectedModel, drainAfter: true)
        }
    }

    func switchSTTModel() async {
        // Cancel any in-flight STT download/load
        if let existing = sttLoadTask {
            existing.cancel()
            await existing.value
            sttLoadTask = nil
        }

        guard state == .idle else {
            Self.log.warning("switchSTTModel deferred — state is \(String(describing: self.state))")
            pendingSTTSwitch = true
            return
        }

        pendingSTTSwitch = false
        state = .downloading(progress: 0)

        sttLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.reloadSTT()
                try Task.checkCancellation()

                self.modelManager.statusMessage = L("download.loading_stt")
                self.stt = try await self.makeSttService()
                self.modelManager.sttReady = (self.stt != nil)
                try Task.checkCancellation()

                self.state = .idle
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                self.state = .error(error.localizedDescription)
                self.resetErrorAfterDelay()
            }
            self.sttLoadTask = nil
            await self.drainPendingSwitches()
        }
    }

    /// Process any model switches that were deferred because state wasn't idle.
    private func drainPendingSwitches() async {
        if pendingLLMSwitch && state == .idle {
            await switchModel()
        }
        if pendingSTTSwitch && state == .idle {
            await switchSTTModel()
        }
    }

    // MARK: - Custom Model Download + Add

    /// Downloads a HuggingFace model, then adds it to the registry only on success.
    /// If cancelled (e.g. user switches models mid-download), the model is never registered.
    func downloadAndAddCustomModel(_ model: ModelOption) async {
        // Cancel any in-flight LLM download/load
        if let existing = llmLoadTask {
            existing.cancel()
            await existing.value
            llmLoadTask = nil
        }

        state = .downloading(progress: 0)

        llmLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.activateLLM(model, drainAfter: true) {
                // Download succeeded — register the model with its measured on-disk size.
                // Set as selected model — triggers onChange → switchModel(), which early-returns
                // because loadedModelPath already matches, then redoes service creation + warmup.
                var finalModel = model
                let measured = ModelRegistry.measureModelOnDisk(model)
                if measured > 0 { finalModel.estimatedMemoryGB = measured }
                ModelRegistry.addModel(finalModel)
                self.modelManager.selectedModel = finalModel
                UserDefaults.standard.set(finalModel.path, forKey: "selectedModelPath")
            }
        }
    }

    // MARK: - On-Demand Model Reload (post-offload)

    /// Reloads STT from disk if it was offloaded. No-op if already loaded.
    private func ensureSTTReady() async throws {
        guard stt == nil else { return }
        modelManager.sttLoading = true
        defer { modelManager.sttLoading = false }
        try await modelManager.reloadSTT()
        stt = try await makeSttService()
        modelManager.sttReady = (stt != nil)
    }

    /// Reloads LLM from disk if it was offloaded. No-op for None sentinel or already-loaded.
    /// Reuses the activateLLM path so warmup runs, but skips the glass sound.
    private func ensureLLMReady() async throws {
        guard !modelManager.selectedModel.isNone else { return }
        guard llm == nil else { return }
        // Use loadModel directly to avoid duplicate sounds from activateLLM
        state = .warmingUp
        let model = modelManager.selectedModel
        try await modelManager.loadModel(model)
        if let container = modelManager.modelContainer {
            llm = makeLLMService(container: container)
        }
        try await llm?.warmup()
        modelManager.keepAlive()
        state = .idle
        guard llm != nil else { throw VoiceEditorError.modelsNotLoaded }
    }

    // MARK: - Voice Edit

    func handleVoiceEdit() async {
        // Toggle: pressing during recording cancels the voice edit
        if state == .listening {
            voiceEditTask?.cancel()
            voiceEditTask = nil
            return
        }

        guard licenseManager.isActivated else {
            state = .error(L("license.not_activated"))
            resetErrorAfterDelay()
            return
        }

        guard state == .idle else { return }

        modelManager.cancelOffload()

        // Reload STT and LLM from disk cache if they were offloaded
        do {
            try await ensureSTTReady()
            try await ensureLLMReady()
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        guard let stt else {
            state = .error(VoiceEditorError.modelsNotLoaded.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        voiceEditTask = Task { [weak self] in
            guard let self else { return }

            let screenContext = await contextCapture.capture(
                mode: contextAwareMode,
                documentBudget: modelManager.selectedModel.documentContextBudget
            )
            var savedClipboard: TextCaptureService.ClipboardSnapshot?

            do {
                savedClipboard = textCapture.saveClipboard()
                let selectedText = try await textCapture.captureSelectedText()

                // Phase 1: Record with live waveform + streaming transcription
                SoundPlayer.shared.playActivation()
                state = .listening

                let session = try await audioCapture.startContinuousRecording(
                    vadDetector: modelManager.vadDetector
                )
                // Expose session so overlay can poll audio level for waveform animation
                activeRecordingSession = session
                liveTranscriptionText = ""

                // Streaming transcription loop — shows live text while recording
                // Path A (legacy): 300ms re-transcription poll
                // Path B (native): Qwen3-ASR StreamingInferenceSession
                let lastTranscription = await runStreamingTranscription(
                    session: session,
                    stt: stt,
                    onTextUpdate: { [weak self] text in
                        self?.liveTranscriptionText = text
                    }
                )

                // Check cancellation after recording phase
                guard !Task.isCancelled else {
                    session.stop()
                    activeRecordingSession = nil
                    liveTranscriptionText = ""
                    if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
                    state = .idle
                    voiceEditTask = nil
                    return
                }

                session.stop()
                activeRecordingSession = nil
                liveTranscriptionText = ""

                // Handle no-speech timeout from VAD
                if session.isNoSpeechTimeout {
                    if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
                    throw AudioCaptureService.AudioCaptureError.noSpeechDetected
                }

                let samples = session.audioBuffer.getAll()
                guard samples.count >= 16_000 else {
                    throw VoiceEditorError.emptyTranscription
                }

                // For native streaming, the session already finalized the text.
                // For legacy polling, do a final transcription on the complete buffer.
                let command: String
                if modelManager.selectedSTTModel.supportsNativeStreaming && !lastTranscription.isEmpty {
                    command = lastTranscription
                } else {
                    state = .transcribing
                    do {
                        command = try await stt.transcribe(samples: samples)
                    } catch {
                        Self.log.error("Final transcription failed, falling back to streaming result: \(error.localizedDescription, privacy: .public)")
                        command = lastTranscription
                    }
                }

                let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCommand.isEmpty else {
                    throw VoiceEditorError.emptyTranscription
                }

                // Reject very short transcriptions that are likely noise/hallucinations
                let wordCount = trimmedCommand.split(separator: " ").count
                guard wordCount >= 2 else {
                    Self.log.warning("Transcription too short (\(wordCount) word): '\(trimmedCommand)' — likely noise")
                    throw VoiceEditorError.emptyTranscription
                }

                let draftMode = selectedText.isEmpty || DraftDetector.isDraftCommand(trimmedCommand)

                // Clear stale multi-turn context when the user has selected new text.
                if !selectedText.isEmpty { lastEditContext = nil }

                if let llm = self.llm {
                    // Phase 3: LLM generation
                    state = .generating

                    let family = modelManager.selectedModel.family
                    let prompt: String
                    let maxTokens: Int

                    // Build effective instruction — prepend previous result for follow-up commands.
                    let effectiveInstruction: String
                    if let ctx = lastEditContext, !ctx.isExpired, selectedText.isEmpty {
                        effectiveInstruction = """
                        Previous result: \(ctx.result)
                        Follow-up: \(trimmedCommand)
                        """
                    } else {
                        effectiveInstruction = trimmedCommand
                    }

                    if draftMode {
                        prompt = family.draftPrompt(instruction: effectiveInstruction, context: screenContext)
                        maxTokens = family.draftMaxTokens
                    } else {
                        prompt = family.editPrompt(text: selectedText, instruction: effectiveInstruction, context: screenContext)
                        maxTokens = family.editMaxTokens(for: selectedText)
                    }

                    var raw = ""
                    raw.reserveCapacity(4096)
                    for try await chunk in llm.generateStream(prompt: prompt, maxTokens: maxTokens) {
                        raw += chunk
                        // Show raw tokens in overlay — postProcess() runs once on the final string.
                        // Running regex cleanup per-token was O(N²); models with enable_thinking=false
                        // produce no thinking blocks to strip mid-stream anyway.
                        streamingLLMText = raw
                    }
                    streamingLLMText = ""
                    var cleaned = OutputCleaner.clean(family.postProcess(raw))
                    cleaned = OutputCleaner.stripEcho(cleaned, instruction: trimmedCommand)

                    guard !cleaned.isEmpty else {
                        throw VoiceEditorError.emptyOutput
                    }

                    try await presentOutput(cleaned, savedClipboard: savedClipboard)
                    lastEditContext = EditContext(instruction: trimmedCommand, result: cleaned, timestamp: Date())
                    SoundPlayer.shared.playCompletion()
                    modelManager.keepAlive()
                } else {
                    // STT-only mode (None selected): paste raw transcript directly
                    try await presentOutput(trimmedCommand, savedClipboard: savedClipboard)
                    SoundPlayer.shared.playCompletion()
                }

                state = .idle
                voiceEditTask = nil
            } catch {
                activeRecordingSession = nil
                liveTranscriptionText = ""
                streamingLLMText = ""
                if let saved = savedClipboard {
                    textCapture.restoreClipboard(saved)
                }
                if Task.isCancelled {
                    state = .idle
                } else {
                    state = .error(error.localizedDescription)
                    resetErrorAfterDelay()
                }
                voiceEditTask = nil
            }
        }
    }

    // MARK: - Grammar Fix

    func handleGrammarFix() async {
        guard licenseManager.isActivated else {
            state = .error(L("license.not_activated"))
            resetErrorAfterDelay()
            return
        }

        guard state == .idle else { return }

        modelManager.cancelOffload()

        // Reload LLM from cache if it was offloaded
        do { try await ensureLLMReady() } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        // None selected → silently no-op (no LLM, no grammar fix)
        guard let llm else { return }

        var savedClipboard: TextCaptureService.ClipboardSnapshot?

        do {
            savedClipboard = textCapture.saveClipboard()
            let selectedText = try await textCapture.captureSelectedText()

            // Bail if nothing selected or only whitespace → delegate to Action Mode
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if let saved = savedClipboard {
                    textCapture.restoreClipboard(saved)
                }
                if let ac = actionCoordinator { await ac.handle() }
                return
            }

            guard trimmed.count > 10 else {
                // Too short — likely accidental capture, not real selected text
                if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
                return
            }

            // Audio cue: start
            SoundPlayer.shared.playActivation()

            state = .generating

            let family = modelManager.selectedModel.family
            let lang = LanguageDetector.detect(trimmed)
            let instruction = Instructions.forLanguage(lang)
            let prompt = family.editPrompt(text: selectedText, instruction: instruction, context: nil)
            let maxTokens = family.editMaxTokens(for: selectedText)

            let raw = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
            let cleaned = OutputCleaner.clean(family.postProcess(raw))

            guard !cleaned.isEmpty else {
                throw VoiceEditorError.emptyOutput
            }

            // Grammar fix always pastes — no overlay display mode for Ctrl+A.
            try await presentOutput(cleaned, savedClipboard: savedClipboard, useDisplayMode: false)

            // Audio cue: done
            SoundPlayer.shared.playCompletion()
            modelManager.keepAlive()

            state = .idle
        } catch {
            if let saved = savedClipboard {
                textCapture.restoreClipboard(saved)
            }
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    // MARK: - Dictation

    func handleDictation() async {
        // Toggle: pressing during dictation stops immediately
        if case .dictating = state {
            await stopDictation()
            return
        }

        guard licenseManager.isActivated else {
            state = .error(L("license.not_activated"))
            resetErrorAfterDelay()
            return
        }

        guard state == .idle else { return }

        modelManager.cancelOffload()

        do { try await ensureSTTReady() } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        guard stt != nil else {
            state = .error(VoiceEditorError.modelsNotLoaded.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        do {
            textCapture.rememberTargetApp()
            let session = try await audioCapture.startContinuousRecording(
                vadDetector: modelManager.vadDetector
            )
            dictationSession = session

            SoundPlayer.shared.playActivation()
            state = .dictating("")
            activeRecordingSession = session

            // Streaming loop — picks native streaming (Path B) or legacy poll (Path A)
            // and auto-stops when silence is detected after speech.
            streamingTask = Task { [weak self] in
                guard let self, let stt = self.stt else { return }
                let finalText = await runStreamingTranscription(
                    session: session,
                    stt: stt,
                    onTextUpdate: { [weak self] text in
                        self?.updateDictationText(text)
                    }
                )
                await MainActor.run { self.lastStreamingTranscription = finalText }

                // If we exited due to no speech timeout, show error and stop
                if !Task.isCancelled && session.isNoSpeechTimeout {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.dictationSession = nil
                        session.stop()
                        self.activeRecordingSession = nil
                        self.state = .error(L("error.no_speech_detected"))
                        self.resetErrorAfterDelay()
                    }
                    return
                }

                // If we exited due to silence (not cancellation), stop dictation.
                if !Task.isCancelled && session.isSilenceDetected {
                    Task { @MainActor [weak self] in
                        await self?.stopDictation()
                    }
                }
            }
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    private func updateDictationText(_ text: String) {
        if case .dictating = state {
            state = .dictating(text)
        }
    }

    private func stopDictation() async {
        // Stop the waveform animation and mic indicator immediately — before any async wait.
        // This gives instant visual feedback when the user presses the stop shortcut.
        activeRecordingSession = nil
        if case .dictating = state { state = .transcribing }

        streamingTask?.cancel()
        // Race streaming task against a 10s timeout so stop-dictation stays responsive
        if let task = streamingTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(10)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        streamingTask = nil

        guard let session = dictationSession else {
            state = .idle
            return
        }
        dictationSession = nil
        session.stop()
        // (activeRecordingSession already cleared above)

        // Final transcription on the complete buffer
        let samples = session.audioBuffer.getAll()
        guard samples.count >= 16_000, let stt else {
            SoundPlayer.shared.playCompletion()
            lastStreamingTranscription = nil
            state = .idle
            return
        }

        do {
            let text: String
            if modelManager.selectedSTTModel.supportsNativeStreaming,
               let streamResult = lastStreamingTranscription, !streamResult.isEmpty {
                text = streamResult
            } else {
                text = try await stt.transcribe(samples: samples)
            }
            lastStreamingTranscription = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .idle
                return
            }

            // Optional polish pass: remove filler words + add punctuation via LLM.
            // Runs only when the setting is on and an LLM is loaded.
            let finalText: String
            if polishDictation, let llm, !modelManager.selectedModel.isNone {
                state = .generating
                finalText = (try? await DictationPolisher.polish(transcript: trimmed, llm: llm)) ?? trimmed
            } else {
                finalText = trimmed
            }

            var savedClipboardOpt: TextCaptureService.ClipboardSnapshot? = textCapture.saveClipboard()
            // Dictation always pastes the raw transcript — never shows in the overlay.
            try await presentOutput(finalText, savedClipboard: savedClipboardOpt, useDisplayMode: false)

            SoundPlayer.shared.playCompletion()
            modelManager.keepAlive()

            state = .idle
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    // MARK: - Output Routing

    /// Routes `text` to either paste (editable element focused) or overlay display mode (non-editable).
    /// Encapsulates clipboard restore so callers don't need to handle it separately.
    /// Always fails open: if editability detection is unavailable, pastes as before.
    /// Routes `text` to paste (editable) or overlay display (non-editable, LLM-produced output only).
    ///
    /// `useDisplayMode` must be `false` for raw dictation results — dictation always pastes, never
    /// shows in the overlay, regardless of whether the focused element is editable.
    private func presentOutput(
        _ text: String,
        savedClipboard: TextCaptureService.ClipboardSnapshot?,
        useDisplayMode: Bool = true
    ) async throws {
        if !useDisplayMode || editabilityDetector.focusedElementIsEditable() {
            // Editable path (or dictation — always paste).
            state = .pasting
            try await textCapture.pasteText(text)
            if let saved = savedClipboard {
                try? await Task.sleep(for: .milliseconds(300))
                textCapture.restoreClipboard(saved)
            }
        } else {
            // Non-editable path — show LLM result in overlay, restore clipboard immediately.
            displayModeResult = text
            state = .idle
            if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
            displayModeClearTask?.cancel()
            displayModeClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.displayModeResult = ""
                self?.displayModeClearTask = nil
            }
        }
    }

    /// Dismisses the display-mode overlay immediately (called by Esc key handler).
    func clearDisplayModeResult() {
        displayModeClearTask?.cancel()
        displayModeClearTask = nil
        displayModeResult = ""
    }

    // MARK: - Helpers

    private func makeSttService() async throws -> (any STTService)? {
        switch modelManager.selectedSTTModel.backend {
        case .fluidAudio:
            guard let models = modelManager.asrModels else { return nil }
            return try await FluidAudioSTT(models: models)
        case .mlxAudio:
            let path = modelManager.selectedSTTModel.path
            guard !path.isEmpty else { return nil }
            return try await MLXAudioSTTService(modelPath: path, cacheDirectory: modelCacheDirectory)
        case .whisperKit:
            let modelName = modelManager.selectedSTTModel.path
            return try await WhisperKitSTTService(modelName: modelName)
        }
    }

    private var modelCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models")
    }

    /// Rebuilds the LLM service wrapper when context mode toggles (updates system prompt).
    /// Cheap operation — no model reload, just creates a new MLXLLMService with the right prompt.
    private func rebuildLLMServiceIfNeeded() {
        guard state == .idle, let container = modelManager.modelContainer else { return }
        llm = makeLLMService(container: container)
    }

    private func makeLLMService(container: ModelContainer) -> MLXLLMService {
        let family = modelManager.selectedModel.family
        let isScreenAware = contextAwareMode != .off
        return MLXLLMService(
            container: container,
            family: family,
            systemPrompt: family.systemPrompt(screenAware: isScreenAware)
        )
    }

    private func resetErrorAfterDelay() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if case .error = self.state {
                self.state = .idle
                await self.drainPendingSwitches()
            }
        }
    }
}
