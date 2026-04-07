import AVFoundation
import Combine
import NaturalLanguage
import UserNotifications
import FluidAudio
import HitokuInference
import MLXAudioSTT
import MLXLMCommon
import os
import SwiftUI

@MainActor
final class ConversationCoordinator: ObservableObject {
    private static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")
    @Published private(set) var state: AppState = .idle

    /// True while any pipeline is active (listening, transcribing, generating, pasting).
    /// Used to show the Cancel button in the menu bar.
    var isActive: Bool {
        switch state {
        case .idle, .error, .downloading, .warmingUp: return false
        default: return true
        }
    }

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
    /// The TTS segment currently being spoken — used by the overlay to highlight text.
    @Published private(set) var ttsSpeakingSegment: String = ""
    private var stt: (any STTService)?
    private var llm: (any LLMService)?
    private var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var dictationSession: AudioCaptureService.ContinuousSession?
    private var streamingTask: Task<Void, Never>?
    private var voiceEditTask: Task<Void, Never>?
    private var grammarFixTask: Task<Void, Never>?
    private let dictationOverlay = DictationOverlayPanel()
    /// Action Mode module. Setting this to nil (or deleting Actions/) fully disables the feature.
    private var actionCoordinator: ActionCoordinator?
    /// Tool executor for web search/fetch during LLM generation. Created lazily when internet access is enabled.
    private var toolExecutor: ToolExecutor?

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

    /// Tracks the current internet access setting to detect changes and rebuild LLM service.
    private var internetAccessEnabled: Bool =
        UserDefaults.standard.bool(forKey: "internetAccessEnabled")
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
                let internet = UserDefaults.standard.bool(forKey: "internetAccessEnabled")
                if internet != self.internetAccessEnabled {
                    self.internetAccessEnabled = internet
                    self.rebuildLLMServiceIfNeeded()
                }
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

        // Phase 1: STT — skip when LiteRT is active (Gemma handles audio natively)
        if modelManager.selectedModel.backendType == .liteRT {
            // LiteRT models have built-in audio understanding — no separate STT needed.
            // This saves ~460MB RAM (Parakeet/WhisperKit model weights).
            modelManager.sttReady = true
        } else if stt == nil {
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
        actionCoordinator?.onDisplayResult = { [weak self] text in self?.displayModeResult = text }

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
            if modelManager.inferenceRouter.isLoaded {
                llm = makeLLMService()
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
        // LiteRT models handle audio natively — no separate STT needed
        if modelManager.selectedModel.backendType == .liteRT {
            modelManager.sttReady = true
            return
        }
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
        if modelManager.inferenceRouter.isLoaded {
            llm = makeLLMService()
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
        await TTSService.shared.stop()
        clearDisplayModeResult()

        // Ensure STT ready (skip for LiteRT)
        do { try await ensureSTTReady() } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        // Ensure LLM is ready — but don't change state (would interrupt recording)
        if llm == nil, !modelManager.selectedModel.isNone {
            do {
                let model = modelManager.selectedModel
                try await modelManager.loadModel(model)
                if modelManager.inferenceRouter.isLoaded {
                    llm = makeLLMService()
                }
                modelManager.keepAlive()
            } catch {
                state = .error(error.localizedDescription)
                resetErrorAfterDelay()
                return
            }
        }

        // STT can be nil when LiteRT is active (Gemma handles audio natively)
        let needsSTT = modelManager.selectedModel.backendType != .liteRT
        guard !needsSTT || stt != nil else {
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
                // LiteRT handles audio natively — no live STT transcription needed
                let lastTranscription: String
                if let stt {
                    lastTranscription = await runStreamingTranscription(
                        session: session,
                        stt: stt,
                        onTextUpdate: { [weak self] text in
                            self?.liveTranscriptionText = text
                        }
                    )
                } else {
                    lastTranscription = ""
                }

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

                // Audio-direct path: when the active backend supports native audio input
                // (e.g. LiteRT + Gemma 4 E2B), skip STT entirely and send raw audio to the LLM.
                let audioDirectMode = (llm as? RoutedLLMService)?.supportsAudioInput == true

                // For native streaming, the session already finalized the text.
                // For legacy polling, do a final transcription on the complete buffer.
                let command: String
                if audioDirectMode {
                    // No STT needed — the model will hear the voice instruction directly.
                    // Use a placeholder; the actual instruction is in the audio data.
                    command = "[voice instruction]"
                } else if modelManager.selectedSTTModel.supportsNativeStreaming && !lastTranscription.isEmpty {
                    command = lastTranscription
                } else {
                    state = .transcribing
                    do {
                        command = try await stt!.transcribe(samples: samples)
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

                    // Capture TTS settings before the stream loop to avoid repeated UserDefaults reads.
                    let ttsEnabled = UserDefaults.standard.bool(forKey: "ttsEnabled")
                    // Always stream TTS when enabled — the editability check only matters at
                    // presentOutput() time. Checking here was wrong because PDF viewers and
                    // other selectable-but-not-editable views report as "editable" to AX.
                    let willStreamTTS = ttsEnabled
                    let ttsBackendStr = UserDefaults.standard.string(forKey: "ttsBackend") ?? "kokoro"
                    let ttsStreamBackend: TtsBackend = ttsBackendStr == "pocketTts" ? .pocketTts : .kokoro
                    var ttsVoice = UserDefaults.standard.string(forKey: "ttsVoice") ?? TtsConstants.recommendedVoice
                    let rawSpeed = UserDefaults.standard.double(forKey: "ttsSpeed")
                    let ttsSpeed = Float(rawSpeed > 0 ? rawSpeed : 1.0)
                    var ttsChunker = StreamingTextChunker()
                    var firstTokenTime: ContinuousClock.Instant? = nil
                    let maxFirstLatency: Duration = .milliseconds(600)

                    // Pre-warm TTS concurrently so the provider is initialized by the time
                    // the first segment is extracted — hides CoreML compilation latency.
                    if willStreamTTS {
                        Task { await TTSService.shared.preWarm(backend: ttsStreamBackend) }
                        await TTSService.shared.setOnSegmentStart { [weak self] segment in
                            self?.ttsSpeakingSegment = segment
                        }
                    }

                    // Pass screenshot to VLM models — they see the image directly.
                    // Text-only models ignore the images parameter (protocol default).
                    let vlmImages: [CGImage] = {
                        guard modelManager.selectedModel.isVLM,
                              let screenshot = screenContext.screenshot else { return [] }
                        return [screenshot]
                    }()

                    var raw = ""
                    raw.reserveCapacity(4096)

                    // Choose stream: audio-direct (LiteRT) or text-based (MLX).
                    let generationStream: AsyncThrowingStream<String, Error>
                    if audioDirectMode, let routedLLM = llm as? RoutedLLMService {
                        // Gemma 4: send audio (voice instruction) + images (screen) together
                        let audioData = AudioEncoder.wavData(from: samples)
                        generationStream = routedLLM.generateStream(
                            prompt: prompt, audio: audioData, images: vlmImages, maxTokens: maxTokens)
                    } else {
                        generationStream = llm.generateStream(prompt: prompt, images: vlmImages, maxTokens: maxTokens)
                    }

                    for try await chunk in generationStream {
                        raw += chunk
                        // Show raw tokens in overlay — postProcess() runs once on the final string.
                        // Running regex cleanup per-token was O(N²); models with enable_thinking=false
                        // produce no thinking blocks to strip mid-stream anyway.
                        streamingLLMText = raw

                        // Stream text segments to TTS as the LLM generates (display mode only).
                        if willStreamTTS {
                            let cleaned = cleanChunkForTTS(chunk)
                            if firstTokenTime == nil,
                               !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                firstTokenTime = ContinuousClock.now
                            }
                            var segments = ttsChunker.feed(cleaned)
                            if segments.isEmpty, let firstTokenTime {
                                let elapsed = ContinuousClock.now - firstTokenTime
                                if elapsed > maxFirstLatency {
                                    let forced = ttsChunker.forceFirstSplit(minChars: 30)
                                    if !forced.isEmpty { segments = forced }
                                }
                            }
                            if !segments.isEmpty {
                                Self.log.info("TTS chunker emitted \(segments.count) segment(s)")
                                // Auto-detect language from first segment (Kokoro only).
                                if ttsStreamBackend == .kokoro,
                                   let detected = autoDetectKokoroVoice(for: segments[0], currentVoice: ttsVoice) {
                                    ttsVoice = detected
                                    Self.log.info("TTS auto-detected voice: \(detected)")
                                }
                            }
                            for segment in segments {
                                await TTSService.shared.enqueue(
                                    text: segment, voice: ttsVoice, speed: ttsSpeed, backend: ttsStreamBackend
                                )
                            }
                        }
                    }
                    streamingLLMText = ""
                    var cleaned = OutputCleaner.clean(family.postProcess(raw))
                    cleaned = OutputCleaner.stripEcho(cleaned, instruction: trimmedCommand)

                    // Tool-use loop: if the LLM emitted a tool call, execute it and re-generate
                    if let toolExecutor = self.toolExecutor {
                        for _ in 0..<ToolExecutor.maxIterations {
                            try Task.checkCancellation()
                            guard let toolCall = await toolExecutor.detectToolCall(in: raw) else { break }

                            Self.log.info("Tool call detected: \(toolCall.name) — executing")
                            let toolResult = try await toolExecutor.execute(toolCall)

                            // Re-generate with tool result appended to the original prompt
                            let augmentedPrompt = prompt + "\n\nTool result for \(toolCall.name):\n\(toolResult)\n\nNow answer the user's question using this information. Output ONLY the final answer — no tool calls."
                            raw = ""
                            for try await chunk in llm.generateStream(prompt: augmentedPrompt, images: vlmImages, maxTokens: maxTokens) {
                                raw += chunk
                                streamingLLMText = raw
                            }
                            streamingLLMText = ""
                            cleaned = OutputCleaner.clean(family.postProcess(raw))
                            cleaned = OutputCleaner.stripEcho(cleaned, instruction: trimmedCommand)
                        }
                        // Strip any residual tool call tags that slipped through
                        cleaned = await toolExecutor.stripToolCallTags(from: cleaned)
                    }

                    guard !cleaned.isEmpty else {
                        throw VoiceEditorError.emptyOutput
                    }

                    // Flush any remaining text that didn't reach a split point.
                    if willStreamTTS, let remainder = ttsChunker.flush() {
                        await TTSService.shared.enqueue(
                            text: remainder, voice: ttsVoice, speed: ttsSpeed, backend: ttsStreamBackend
                        )
                    }

                    try await presentOutput(cleaned, savedClipboard: savedClipboard, ttsStreamedAlready: willStreamTTS)
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
                await TTSService.shared.stop()
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
        await TTSService.shared.stop()
        clearDisplayModeResult()

        // Reload LLM from cache if it was offloaded
        do { try await ensureLLMReady() } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        // None selected → silently no-op (no LLM, no grammar fix)
        guard let llm else { return }

        // Snapshot clipboard and detect selection before spawning the task,
        // so clipboard state is captured on the current call stack.
        let savedClipboard = textCapture.saveClipboard()
        let selectedText: String
        do {
            selectedText = try await textCapture.captureSelectedText()
        } catch {
            textCapture.restoreClipboard(savedClipboard)
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing selected → Action Mode. Load STT first (not needed for grammar fix,
        // but required for the voice recording that follows).
        if trimmed.isEmpty {
            textCapture.restoreClipboard(savedClipboard)
            do { try await ensureSTTReady() } catch {
                state = .error(error.localizedDescription)
                resetErrorAfterDelay()
                return
            }
            if let ac = actionCoordinator { await ac.handle() }
            return
        }

        guard trimmed.count > 10 else {
            // Too short — likely accidental capture, not real selected text
            textCapture.restoreClipboard(savedClipboard)
            return
        }

        // Wrap the generate + paste pipeline in a stored task so it can be
        // cancelled mid-generation via cancelActiveOperation().
        grammarFixTask = Task { [weak self] in
            guard let self else { return }
            do {
                SoundPlayer.shared.playActivation()
                state = .generating

                let family = modelManager.selectedModel.family
                let lang = LanguageDetector.detect(trimmed)
                let instruction = Instructions.forLanguage(lang)
                let prompt = family.editPrompt(text: selectedText, instruction: instruction, context: nil)
                let maxTokens = family.editMaxTokens(for: selectedText)

                let raw = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
                try Task.checkCancellation()
                let cleaned = OutputCleaner.clean(family.postProcess(raw))

                guard !cleaned.isEmpty else { throw VoiceEditorError.emptyOutput }

                // Grammar fix always pastes — no overlay display mode for Ctrl+A.
                try await presentOutput(cleaned, savedClipboard: savedClipboard, useDisplayMode: false)

                SoundPlayer.shared.playCompletion()
                modelManager.keepAlive()
                state = .idle
            } catch is CancellationError {
                textCapture.restoreClipboard(savedClipboard)
                state = .idle
            } catch {
                textCapture.restoreClipboard(savedClipboard)
                state = .error(error.localizedDescription)
                resetErrorAfterDelay()
            }
            grammarFixTask = nil
        }
    }

    /// Cancels any active grammar-fix or voice-edit operation and returns to idle.
    func cancelActiveOperation() {
        grammarFixTask?.cancel()
        grammarFixTask = nil
        voiceEditTask?.cancel()
        voiceEditTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        state = .idle
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
        await TTSService.shared.stop()
        clearDisplayModeResult()

        // Dictation always needs STT — even when LiteRT is active or "None" STT selected.
        // Temporarily switch to Parakeet if needed, then load.
        if stt == nil {
            let savedSTT = modelManager.selectedSTTModel
            if savedSTT.isNone || modelManager.selectedModel.backendType == .liteRT {
                // Force Parakeet for dictation
                modelManager.selectedSTTModel = STTModelRegistry.defaultModel
            }
            modelManager.sttLoading = true
            do {
                try await modelManager.reloadSTT()
                stt = try await makeSttService()
                modelManager.sttReady = (stt != nil)
            } catch {
                state = .error(error.localizedDescription)
                resetErrorAfterDelay()
                modelManager.sttLoading = false
                modelManager.selectedSTTModel = savedSTT
                return
            }
            modelManager.sttLoading = false
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
        useDisplayMode: Bool = true,
        ttsStreamedAlready: Bool = false
    ) async throws {
        if !useDisplayMode || editabilityDetector.focusedElementIsEditable() {
            // Editable path (or dictation — always paste).
            // If TTS was streamed (display mode detected at generation start) but focus
            // changed to an editable field mid-generation, stop orphaned TTS playback.
            if ttsStreamedAlready { await TTSService.shared.stop() }
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
            // Capture TTS settings synchronously before entering the Task closure.
            let ttsEnabled = UserDefaults.standard.bool(forKey: "ttsEnabled")
            let ttsBackendStr = UserDefaults.standard.string(forKey: "ttsBackend") ?? "kokoro"
            let ttsBackend: TtsBackend = ttsBackendStr == "pocketTts" ? .pocketTts : .kokoro
            let ttsVoice = UserDefaults.standard.string(forKey: "ttsVoice") ?? TtsConstants.recommendedVoice
            let rawSpeed = UserDefaults.standard.double(forKey: "ttsSpeed")
            let ttsSpeed = Float(rawSpeed > 0 ? rawSpeed : 1.0)
            displayModeClearTask?.cancel()
            displayModeClearTask = Task { [weak self] in
                // TTS: if sentences were already streamed into the queue, wait for the
                // queue to drain. Otherwise synthesize the full text as a single utterance.
                // The 30s timer only starts after audio finishes (or immediately if TTS off).
                if ttsEnabled {
                    // Ensure highlight callback is set for both paths.
                    await TTSService.shared.setOnSegmentStart { [weak self] segment in
                        self?.ttsSpeakingSegment = segment
                    }
                    if ttsStreamedAlready {
                        await TTSService.shared.waitForQueue()
                    } else {
                        await TTSService.shared.speak(
                            text: text, voice: ttsVoice, speed: ttsSpeed, backend: ttsBackend
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.displayModeResult = ""
                self?.displayModeClearTask = nil
            }
        }
    }

    /// Dismisses the display-mode overlay and stops TTS playback (called by Esc key handler).
    func clearDisplayModeResult() {
        displayModeClearTask?.cancel()
        displayModeClearTask = nil
        displayModeResult = ""
        Task { await TTSService.shared.stop() }
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

    private var modelCacheDirectory: URL { ModelManager.modelsCacheRoot }

    /// Rebuilds the LLM service wrapper when context mode toggles (updates system prompt).
    /// Cheap operation — no model reload, just creates a new RoutedLLMService with the right prompt.
    private func rebuildLLMServiceIfNeeded() {
        guard state == .idle, modelManager.inferenceRouter.isLoaded else { return }
        llm = makeLLMService()
    }

    private func makeLLMService() -> RoutedLLMService {
        let family = modelManager.selectedModel.family
        let isScreenAware = contextAwareMode != .off
        var systemPrompt = family.systemPrompt(screenAware: isScreenAware)

        // Inject tool definitions when internet access is enabled and the model supports it
        let internetEnabled = UserDefaults.standard.bool(forKey: "internetAccessEnabled")
        if internetEnabled && family.supportsToolUse {
            let executor = makeToolExecutor()
            toolExecutor = executor
            let toolPrompt = buildToolDefinitionsPrompt()
            systemPrompt += "\n\n" + toolPrompt
        } else {
            toolExecutor = nil
        }

        return RoutedLLMService(
            router: modelManager.inferenceRouter,
            family: family,
            systemPrompt: systemPrompt
        )
    }

    /// Creates a ToolExecutor with web search and URL fetch tools.
    private func makeToolExecutor() -> ToolExecutor {
        let searchService = DuckDuckGoSearchService()
        let fetchService = ReadabilityWebFetcher()
        let tools: [any Tool] = [
            WebSearchTool(searchService: searchService),
            FetchURLTool(fetchService: fetchService),
            ListEventsTool(),
            FindFreeTimeTool(),
            CheckAvailabilityTool(),
        ]
        return ToolExecutor(tools: tools)
    }

    /// Builds the tool definitions prompt string synchronously (avoids actor hop).
    /// Mirrors ToolExecutor.toolDefinitionsPrompt but without requiring an actor hop.
    private func buildToolDefinitionsPrompt() -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let nowISO = isoFmt.string(from: Date())
        let weekday = Calendar.current.weekdaySymbols[
            Calendar.current.component(.weekday, from: Date()) - 1
        ]
        return """
        Current date and time: \(nowISO) (\(weekday))

        You have access to the following tools to help answer questions:

        - **web_search**: Search the web for current information.
          Parameters: {"query": "your search query"}
        - **fetch_url**: Fetch and read a web page.
          Parameters: {"url": "https://example.com/page"}
        - **list_events**: List calendar events for a date range.
          Parameters: {"start_date": "YYYY-MM-DD", "end_date": "YYYY-MM-DD"}
        - **find_free_time**: Find free time slots on a given date.
          Parameters: {"date": "YYYY-MM-DD", "start_hour": "9", "end_hour": "18"}
        - **check_availability**: Check if a specific time is free.
          Parameters: {"datetime": "YYYY-MM-DDTHH:mm", "duration_minutes": "60"}

        When you need to use a tool, output EXACTLY this format (no other text around it):
        <tool_call>
        {"name": "TOOL_NAME", "arguments": {"param": "value"}}
        </tool_call>

        Use tools when:
        - The user asks about current events, news, or time-sensitive information
        - The user asks about their calendar, schedule, availability, or free time
        - The user mentions or asks about a specific URL
        - The user explicitly asks you to search or look something up

        Do NOT use tools for:
        - Text editing, rewriting, or grammar fixes
        - Creative writing or drafting
        - Questions you can confidently answer from your training data

        After receiving tool results, incorporate the information naturally into your response. \
        Output ONLY the final answer text -- no tool call tags in the final response.
        """
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

    /// Strips TTS-unfriendly artifacts and converts numbers to words.
    /// Lightweight — runs per-chunk during streaming. The full OutputCleaner
    /// still runs on the final assembled text.
    private func cleanChunkForTTS(_ chunk: String) -> String {
        var t = chunk
        t = t.replacingOccurrences(of: "<think>", with: "")
        t = t.replacingOccurrences(of: "</think>", with: "")
        t = t.replacingOccurrences(of: "<|think|>", with: "")
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "<|assistant|>", with: "")
        t = t.replacingOccurrences(of: "<|end|>", with: "")
        t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        t = t.replacingOccurrences(of: "<|im_start|>", with: "")
        // Convert numbers to words so Kokoro can pronounce them.
        t = Self.convertNumbersToWords(t)
        return t
    }

    /// Replaces digit sequences with their spelled-out equivalents.
    /// Handles integers and decimals. Uses the current locale for natural phrasing.
    private static let spellOutFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .spellOut
        fmt.locale = Locale(identifier: "en_US")
        return fmt
    }()

    private static func convertNumbersToWords(_ text: String) -> String {
        // Match sequences of digits, optionally with a decimal point (e.g. "3.14", "42", "1000")
        let pattern = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        // Process matches in reverse order to preserve indices
        let matches = pattern.matches(in: text, range: range)
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let numStr = String(result[swiftRange])
            if let number = Double(numStr),
               let spelled = spellOutFormatter.string(from: NSNumber(value: number)) {
                result.replaceSubrange(swiftRange, with: spelled)
            }
        }
        return result
    }

    // MARK: - TTS Language Detection

    /// Kokoro voice prefix → NLLanguage mapping.
    /// Each prefix is a two-letter code: first letter = language, second = gender (f/m).
    private static let kokoroLanguageMap: [NLLanguage: String] = [
        .english: "af",      // American English female (default)
        .spanish: "ef",      // Spanish (LATAM) female
        .french: "ff",       // French female
        .hindi: "hf",        // Hindi female
        .italian: "if",      // Italian female
        .japanese: "jf",     // Japanese female
        .portuguese: "pf",   // Brazilian Portuguese female
        .simplifiedChinese: "zf",  // Mandarin Chinese female
        .traditionalChinese: "zf",
    ]

    /// Detects the dominant language of `text` and returns the best Kokoro female voice
    /// for that language. Returns nil if the language matches the user's current voice
    /// or if detection is ambiguous (< 80% confidence).
    private func autoDetectKokoroVoice(for text: String, currentVoice: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let detected = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[detected],
              confidence >= 0.8 else {
            return nil  // Ambiguous — keep user's selection
        }

        // Find the prefix for the detected language.
        guard let targetPrefix = Self.kokoroLanguageMap[detected] else {
            return nil  // Unsupported language — keep user's selection
        }

        // If user's voice already matches the detected language, no change needed.
        if currentVoice.hasPrefix(targetPrefix) { return nil }

        // Find the first available female voice with the target prefix.
        let match = KokoroTTSProvider.femaleVoices.first { $0.hasPrefix(targetPrefix) }
        return match
    }
}
