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
    static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")
    @Published var state: AppState = .idle

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

    let textCapture = TextCaptureService()
    let audioCapture = AudioCaptureService()
    let contextCapture = ContextCaptureService()
    let editabilityDetector: any EditabilityDetector
    let preferences = PreferencesStore()

    /// Non-empty when the last result was displayed in the overlay instead of pasted
    /// (focused element was not editable). Auto-cleared after 20 seconds.
    @Published var displayModeResult: String = ""
    /// The TTS segment currently being spoken — used by the overlay to highlight text.
    @Published var ttsSpeakingSegment: String = ""
    var stt: (any STTService)?
    var llm: (any LLMService)?
    private var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()
    var dictationSession: AudioCaptureService.ContinuousSession?
    var streamingTask: Task<Void, Never>?
    var voiceEditTask: Task<Void, Never>?
    var grammarFixTask: Task<Void, Never>?
    private let dictationOverlay = DictationOverlayPanel()
    /// Action Mode module. Setting this to nil (or deleting Actions/) fully disables the feature.
    private var actionCoordinator: ActionCoordinator?
    /// Tool executor for web search/fetch during LLM generation. Created lazily when internet access is enabled.
    var toolExecutor: ToolExecutor?

    /// Live transcription text for the overlay (updated during streaming; empty = show status label).
    @Published var liveTranscriptionText: String = ""
    /// Accumulating LLM output shown in the overlay during generation; cleared before paste.
    @Published var streamingLLMText: String = ""
    /// The active recording session — non-nil while the mic is recording.
    /// DictationOverlayPanel subscribes to this to start/stop level polling.
    @Published var activeRecordingSession: AudioCaptureService.ContinuousSession?

    @Published var contextAwareMode: ContextAwareMode =
        ContextAwareMode(rawValue: UserDefaults.standard.string(forKey: "contextAwareMode") ?? "off") ?? .off

    /// When true, raw dictation transcripts are passed through a lightweight LLM pass
    /// that removes filler words and adds punctuation — without changing actual words.
    /// Only takes effect when an LLM is loaded (not the None sentinel).
    @Published var polishDictation: Bool =
        UserDefaults.standard.bool(forKey: "polishDictation")

    /// Tracks the current internet access setting to detect changes and rebuild LLM service.
    var internetAccessEnabled: Bool =
        UserDefaults.standard.bool(forKey: "internetAccessEnabled")
    /// Last finalized text from a native streaming session (Qwen3-ASR).
    /// Set by `runStreamingTranscription` for `stopDictation()` to use.
    var lastStreamingTranscription: String?

    /// Stores the last successful voice-edit result for follow-up commands.
    private struct EditContext {
        let instruction: String
        let result: String
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 300 }
    }
    private var lastEditContext: EditContext?

    /// Cancellable model-loading tasks so a new switch can abort an in-flight download.
    var llmLoadTask: Task<Void, Never>?
    var sttLoadTask: Task<Void, Never>?
    /// Scheduled auto-clear for display-mode results; cancelled early by clearDisplayModeResult().
    private var displayModeClearTask: Task<Void, Never>?

    /// Pending model switches that couldn't run because state wasn't idle.
    var pendingLLMSwitch = false
    var pendingSTTSwitch = false

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
            guard let self else { return }
            self.objectWillChange.send()
        }.store(in: &cancellables)

        modelManager.objectWillChange.sink { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
        }.store(in: &cancellables)

        licenseManager.objectWillChange.sink { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
        }.store(in: &cancellables)

        // Re-try hotkey registration when accessibility is granted later
        permissions.onAccessibilityGranted = { [weak self] in
            self?.setupHotkeys()
        }

        // Rebuild LLM service when context awareness mode changes (updates system prompt)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let newMode = self.preferences.contextAwareMode
                if newMode != self.contextAwareMode {
                    self.contextAwareMode = newMode
                    self.rebuildLLMServiceIfNeeded()
                }
                let polish = self.preferences.polishDictation
                if polish != self.polishDictation { self.polishDictation = polish }
                let internet = self.preferences.internetAccessEnabled
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

        // Phase 1: STT — always load (needed for dictation even with LiteRT/Gemma 4)
        // If the user has "None" selected (e.g. from a previous Gemma-only session),
        // switch to Parakeet so dictation works out of the box.
        if modelManager.selectedSTTModel.isNone {
            modelManager.selectedSTTModel = STTModelRegistry.defaultModel
        }
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

    // Model lifecycle methods are in ConversationCoordinator+ModelLifecycle.swift

    /// Snapshot NSScreen.main at hotkey-press time so the overlay appears on the
    /// correct monitor even if async setup shifts focus before the panel is created.
    func captureTargetScreen() {
        dictationOverlay.targetScreen = NSScreen.main
    }

    // MARK: - Voice Edit

    /// Prevents re-entry during async setup (model loading, STT init).
    private var voiceEditSetupInProgress = false

    func handleVoiceEdit() async {
        captureTargetScreen()

        // Toggle: pressing during recording cancels the voice edit
        if state == .listening {
            voiceEditTask?.cancel()
            voiceEditTask = nil
            state = .idle
            return
        }

        // Cancel if pressed during setup (before recording starts)
        if voiceEditSetupInProgress {
            voiceEditSetupInProgress = false
            state = .idle
            return
        }

        guard licenseManager.isActivated else {
            state = .error(L("license.not_activated"))
            resetErrorAfterDelay()
            return
        }

        guard state == .idle else { return }

        voiceEditSetupInProgress = true
        clearDisplayModeResult()
        modelManager.cancelOffload()
        modelManager.cancelSTTOffload()
        Task { await TTSService.shared.stop() }

        // Ensure STT ready (skip for LiteRT)
        do { try await ensureSTTReady() } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        // Ensure LLM is ready
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

        voiceEditSetupInProgress = false
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
                    // No STT (LiteRT audio-direct) — wait for silence detection manually.
                    // runStreamingTranscription normally does this polling loop; replicate it here.
                    while !Task.isCancelled && !session.isSilenceDetected {
                        try await Task.sleep(for: .milliseconds(100))
                    }
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
                    // Skip multi-turn for audio-direct: the model hears the instruction in the audio,
                    // so "[voice instruction]" placeholder must not be wrapped in follow-up context.
                    let effectiveInstruction: String
                    if !audioDirectMode, let ctx = lastEditContext, !ctx.isExpired, selectedText.isEmpty {
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

                    // TTS is disabled during voice edit — the result is pasted or shown
                    // in the overlay. TTS during generation also causes GPU memory contention
                    // with the LLM (PocketTTS uses MLX too), which can produce 0-token output.
                    let willStreamTTS = false
                    let tts = self.preferences.ttsSettings
                    let ttsStreamBackend = tts.backend
                    var ttsVoice = tts.voice
                    let ttsSpeed = tts.speed
                    var ttsChunker = StreamingTextChunker()
                    var thinkingFilter = ThinkingBlockFilter()
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

                    // Pass screenshot to VLM models — only when "Allow vision" is enabled.
                    // This applies to both MLX (Qwen3.5) and LiteRT (Gemma 4).
                    let visionEnabled = UserDefaults.standard.bool(forKey: "visionEnabled")
                    let vlmImages: [CGImage] = {
                        guard visionEnabled, modelManager.selectedModel.isVLM,
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
                        // Show tokens in overlay — but hide tool call tags from the user.
                        // If a <tool_call> is in progress, show a status message instead.
                        if raw.contains("<tool_call>") {
                            streamingLLMText = "Searching…"
                        } else {
                            streamingLLMText = raw
                        }

                        // Stream text segments to TTS as the LLM generates (display mode only).
                        if willStreamTTS {
                            // Filter out thinking blocks before TTS — Gemma 4 thinking
                            // arrives as streaming tokens that would be spoken aloud.
                            let filtered = thinkingFilter.feed(chunk)
                            let cleaned = cleanChunkForTTS(filtered)
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

                    // Tool-use loop: if the LLM emitted a tool call, execute it and re-generate
                    if let toolExecutor = self.toolExecutor {
                        for _ in 0..<ToolExecutor.maxIterations {
                            try Task.checkCancellation()
                            guard let toolCall = await toolExecutor.detectToolCall(in: raw) else { break }

                            Self.log.info("Tool call detected: \(toolCall.name) — executing")
                            streamingLLMText = "Using \(toolCall.name)…"
                            let toolResult = try await toolExecutor.execute(toolCall)

                            // Re-generate with tool result appended to the original prompt
                            let augmentedPrompt = prompt + "\n\nTool result for \(toolCall.name):\n\(toolResult)\n\nNow answer the user's question using this information. Output ONLY the final answer — no tool calls."
                            raw = ""
                            streamingLLMText = ""
                            for try await chunk in llm.generateStream(prompt: augmentedPrompt, images: vlmImages, maxTokens: maxTokens) {
                                raw += chunk
                                streamingLLMText = raw
                            }
                            streamingLLMText = ""
                            cleaned = OutputCleaner.clean(family.postProcess(raw))
                            // stripEcho removed — prompt improvements prevent echoing at the source
                        }
                        // Strip any residual tool call tags that slipped through
                        cleaned = await toolExecutor.stripToolCallTags(from: cleaned)
                    }

                    guard !cleaned.isEmpty else {
                        throw VoiceEditorError.emptyOutput
                    }

                    // Flush any remaining text that didn't reach a split point.
                    if willStreamTTS {
                        // Flush thinking filter first — any buffered non-thinking text
                        let thinkingRemainder = thinkingFilter.flush()
                        if !thinkingRemainder.isEmpty {
                            let cleanedRemainder = cleanChunkForTTS(thinkingRemainder)
                            _ = ttsChunker.feed(cleanedRemainder)
                        }
                        if let remainder = ttsChunker.flush() {
                            await TTSService.shared.enqueue(
                                text: remainder, voice: ttsVoice, speed: ttsSpeed, backend: ttsStreamBackend
                            )
                        }
                    }

                    try await presentOutput(cleaned, savedClipboard: savedClipboard, ttsStreamedAlready: willStreamTTS)
                    lastEditContext = EditContext(instruction: trimmedCommand, result: cleaned, timestamp: Date())
                    SoundPlayer.shared.playCompletion()
                    Task.detached {
                        await TranscriptionStore.shared.save(
                            mode: .voiceEdit,
                            transcription: trimmedCommand,
                            llmResponse: cleaned,
                            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                            modelName: self.modelManager.selectedModel.name
                        )
                    }
                    modelManager.keepAlive()
                    if stt != nil { modelManager.keepSTTAlive() }
                } else {
                    // STT-only mode (None selected): paste raw transcript directly
                    try await presentOutput(trimmedCommand, savedClipboard: savedClipboard)
                    SoundPlayer.shared.playCompletion()
                    Task.detached {
                        await TranscriptionStore.shared.save(
                            mode: .voiceEdit,
                            transcription: trimmedCommand,
                            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
                        )
                    }
                    if stt != nil { modelManager.keepSTTAlive() }
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
        captureTargetScreen()

        guard licenseManager.isActivated else {
            state = .error(L("license.not_activated"))
            resetErrorAfterDelay()
            return
        }

        guard state == .idle else { return }

        modelManager.cancelOffload()
        modelManager.cancelSTTOffload()
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
                Task.detached {
                    await TranscriptionStore.shared.save(
                        mode: .grammarFix,
                        transcription: selectedText,
                        llmResponse: cleaned,
                        activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                        modelName: self.modelManager.selectedModel.name
                    )
                }
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

    // Dictation methods are in ConversationCoordinator+Dictation.swift

    // MARK: - Output Routing

    /// Routes `text` to either paste (editable element focused) or overlay display mode (non-editable).
    /// Encapsulates clipboard restore so callers don't need to handle it separately.
    /// Always fails open: if editability detection is unavailable, pastes as before.
    /// Routes `text` to paste (editable) or overlay display (non-editable, LLM-produced output only).
    ///
    /// `useDisplayMode` must be `false` for raw dictation results — dictation always pastes, never
    /// shows in the overlay, regardless of whether the focused element is editable.
    func presentOutput(
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
            let tts = preferences.ttsSettings
            let ttsEnabled = tts.enabled
            let ttsBackend = tts.backend
            let ttsVoice = tts.voice
            let ttsSpeed = tts.speed
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
        ttsSpeakingSegment = ""
        Task { await TTSService.shared.stop() }
    }

    // MARK: - Helpers

    func makeSttService() async throws -> (any STTService)? {
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

    var modelCacheDirectory: URL { ModelManager.modelsCacheRoot }

    /// Rebuilds the LLM service wrapper when context mode toggles (updates system prompt).
    /// Cheap operation — no model reload, just creates a new RoutedLLMService with the right prompt.
    func rebuildLLMServiceIfNeeded() {
        guard state == .idle, modelManager.inferenceRouter.isLoaded else { return }
        llm = makeLLMService()
    }

    func makeLLMService() -> RoutedLLMService {
        let family = modelManager.selectedModel.family
        let isScreenAware = contextAwareMode != .off
        var systemPrompt = family.systemPrompt(screenAware: isScreenAware)

        // Inject tool definitions — calendar tools always available, internet tools gated by preference
        if family.supportsToolUse {
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

    /// Creates a ToolExecutor. Calendar tools are always included;
    /// internet tools (web search, URL fetch) only when internet access is enabled.
    func makeToolExecutor() -> ToolExecutor {
        var tools: [any Tool] = [
            ListEventsTool(),
            FindFreeTimeTool(),
            CheckAvailabilityTool(),
        ]
        if preferences.internetAccessEnabled {
            let searchService = DuckDuckGoSearchService()
            let fetchService = ReadabilityWebFetcher()
            tools.insert(WebSearchTool(searchService: searchService), at: 0)
            tools.insert(FetchURLTool(fetchService: fetchService), at: 1)
        }
        return ToolExecutor(tools: tools)
    }

    /// Builds the tool definitions prompt string synchronously (avoids actor hop).
    /// Mirrors ToolExecutor.toolDefinitionsPrompt but without requiring an actor hop.
    func buildToolDefinitionsPrompt() -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let nowISO = isoFmt.string(from: Date())
        let weekday = Calendar.current.weekdaySymbols[
            Calendar.current.component(.weekday, from: Date()) - 1
        ]

        let internetEnabled = preferences.internetAccessEnabled
        var toolDefs = """
        - **list_events**: List calendar events for a date range.
          Parameters: {"start_date": "YYYY-MM-DD", "end_date": "YYYY-MM-DD"}
        - **find_free_time**: Find free time slots on a given date.
          Parameters: {"date": "YYYY-MM-DD", "start_hour": "9", "end_hour": "18"}
        - **check_availability**: Check if a specific time is free.
          Parameters: {"datetime": "YYYY-MM-DDTHH:mm", "duration_minutes": "60"}
        """
        if internetEnabled {
            toolDefs = """
            - **web_search**: Search the web for current information.
              Parameters: {"query": "your search query"}
            - **fetch_url**: Fetch and read a web page.
              Parameters: {"url": "https://example.com/page"}
            """ + "\n" + toolDefs
        }

        var useRules = """
        - The user asks about their calendar, schedule, availability, or free time
        """
        if internetEnabled {
            useRules = """
            - The user asks about current events, news, or time-sensitive information
            - The user mentions or asks about a specific URL
            - The user explicitly asks you to search or look something up
            """ + "\n" + useRules
        }

        return """
        Current date and time: \(nowISO) (\(weekday))

        You have access to the following tools to help answer questions:

        \(toolDefs)

        When you need to use a tool, output EXACTLY this format (no other text around it):
        <tool_call>
        {"name": "TOOL_NAME", "arguments": {"param": "value"}}
        </tool_call>

        Use tools when:
        \(useRules)

        Do NOT use tools for:
        - Text editing, rewriting, or grammar fixes
        - Creative writing or drafting
        - Questions you can confidently answer from your training data
        - Opening or launching applications

        After receiving tool results, incorporate the information naturally into your response. \
        Output ONLY the final answer text -- no tool call tags in the final response.
        """
    }

    func resetErrorAfterDelay() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if case .error = self.state {
                self.state = .idle
                await self.drainPendingSwitches()
            }
        }
    }

    // TTS helper methods are in ConversationCoordinator+TTSHelpers.swift
}
