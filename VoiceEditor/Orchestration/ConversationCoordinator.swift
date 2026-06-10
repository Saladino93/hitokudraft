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
@Observable
final class ConversationCoordinator {
    static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")
    var state: AppState = .idle

    /// True while any pipeline is active (listening, transcribing, generating, pasting).
    /// Used to show the Cancel button in the menu bar.
    var isActive: Bool {
        switch state {
        case .idle, .error, .downloading, .warmingUp: return false
        default: return true
        }
    }

    let permissions = PermissionsCoordinator()
    let modelManager: ModelManager
    /// Model session (services, load/switch lifecycle) — see ModelSessionController.
    /// Internal (not private) so the +ModelLifecycle forwarder extension can reach it;
    /// pipelines should go through the coordinator forwarders, not this directly.
    let models: ModelSessionController
    let licenseManager = LicenseManager()

    let textCapture = TextCaptureService()
    let audioCapture = AudioCaptureService()
    let contextCapture = ContextCaptureService()
    let editabilityDetector: any EditabilityDetector
    let preferences = PreferencesStore()

    /// Display-mode (overlay result) state machine — see DisplayResultController.
    /// Forwarders below keep the coordinator's public API unchanged.
    private let display = DisplayResultController()

    /// Non-empty when the last result was displayed in the overlay instead of pasted
    /// (focused element was not editable). Auto-cleared after the dismiss countdown.
    var displayModeResult: String {
        get { display.result }
        set { display.result = newValue }
    }
    /// The TTS segment currently being spoken — used by the overlay to highlight text.
    var ttsSpeakingSegment: String {
        get { display.speakingSegment }
        set { display.speakingSegment = newValue }
    }
    var stt: (any STTService)? {
        get { models.stt }
        set { models.stt = newValue }
    }
    var llm: (any LLMService)? {
        get { models.llm }
        set { models.llm = newValue }
    }
    @ObservationIgnored private var hotkeyManager: HotkeyManager?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var dictationSession: AudioCaptureService.ContinuousSession?
    @ObservationIgnored var streamingTask: Task<Void, Never>?
    @ObservationIgnored var voiceEditTask: Task<Void, Never>?
    @ObservationIgnored var grammarFixTask: Task<Void, Never>?
    private let dictationOverlay = DictationOverlayPanel()
    /// Action Mode module. Setting this to nil (or deleting Actions/) fully disables the feature.
    @ObservationIgnored private var actionCoordinator: ActionCoordinator?
    /// Tool executor for web search/fetch during LLM generation. Created lazily when internet access is enabled.
    var toolExecutor: ToolExecutor? {
        get { models.toolExecutor }
        set { models.toolExecutor = newValue }
    }

    /// Live transcription text for the overlay (updated during streaming; empty = show status label).
    var liveTranscriptionText: String = ""
    /// Accumulating LLM output shown in the overlay during generation; cleared before paste.
    var streamingLLMText: String = ""
    /// The active recording session — non-nil while the mic is recording.
    /// DictationOverlayPanel observes this to start/stop level polling.
    var activeRecordingSession: AudioCaptureService.ContinuousSession?

    var contextAwareMode: ContextAwareMode =
        ContextAwareMode(rawValue: UserDefaults.standard.string(forKey: "contextAwareMode") ?? "off") ?? .off

    /// When true, raw dictation transcripts are passed through a lightweight LLM pass
    /// that removes filler words and adds punctuation — without changing actual words.
    /// Only takes effect when an LLM is loaded (not the None sentinel).
    var polishDictation: Bool =
        UserDefaults.standard.bool(forKey: "polishDictation")

    /// Tracks the current internet access setting to detect changes and rebuild LLM service.
    @ObservationIgnored var internetAccessEnabled: Bool =
        UserDefaults.standard.bool(forKey: "internetAccessEnabled")
    /// Last finalized text from a native streaming session (Qwen3-ASR).
    /// Set by `runStreamingTranscription` for `stopDictation()` to use.
    @ObservationIgnored var lastStreamingTranscription: String?

    /// Stores the last successful voice-edit result for follow-up commands.
    private struct EditContext {
        let instruction: String
        let result: String
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 300 }
    }
    @ObservationIgnored private var lastEditContext: EditContext?

    /// Cancellable model-loading tasks so a new switch can abort an in-flight download.
    var llmLoadTask: Task<Void, Never>? {
        get { models.llmLoadTask }
        set { models.llmLoadTask = newValue }
    }
    var sttLoadTask: Task<Void, Never>? {
        get { models.sttLoadTask }
        set { models.sttLoadTask = newValue }
    }
    /// Pending model switches that couldn't run because state wasn't idle.
    var pendingLLMSwitch: Bool {
        get { models.pendingLLMSwitch }
        set { models.pendingLLMSwitch = newValue }
    }
    var pendingSTTSwitch: Bool {
        get { models.pendingSTTSwitch }
        set { models.pendingSTTSwitch = newValue }
    }

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
        let manager = ModelManager()
        self.modelManager = manager
        self.models = ModelSessionController(modelManager: manager, preferences: PreferencesStore())

        // AppState bridge: the model session drives pipeline state through the
        // coordinator so AppState stays single-source (same pattern as ActionCoordinator).
        models.getState = { [weak self] in self?.state ?? .idle }
        models.setState = { [weak self] in self?.state = $0 }
        models.getContextAwareMode = { [weak self] in self?.contextAwareMode ?? .off }
        models.scheduleErrorReset = { [weak self] in self?.resetErrorAfterDelay() }

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

        // (Offload → service-niling observation moved into ModelSessionController.)

        // Overlay observes published state instead of being commanded directly
        dictationOverlay.observe(self)

        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                await self?.setup()
            }
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

        // Pre-warm TTS so the first "Read Aloud" or streaming TTS is instant.
        // CoreML compilation can take 1-2s cold — doing it at launch hides it entirely.
        Task.detached(priority: .background) {
            let backend = PreferencesStore().ttsSettings.backend
            await TTSService.shared.preWarm(backend: backend)
        }

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

        // Capture editability IMMEDIATELY — before any async work, model loading, or
        // overlay display that could shift AX focus away from the target app.
        // Apple Mail, Gmail, Notion etc. use WebKit editors that lose AX focus easily.
        let targetIsEditable = editabilityDetector.focusedElementIsEditable()

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
        voiceEditTask = Task { [weak self, targetIsEditable] in
            guard let self else { return }

            // Latency split (see docs/SPEECH_AND_AI_DESIGN.md). Instants captured at each
            // phase boundary; deltas are computed and logged after insertion.
            let tStart = Date()
            var tRecordStop: Date?
            var tCommandReady: Date?
            var tFirstToken: Date?
            var tGenDone: Date?
            var tInserted: Date?

            let screenContext = await contextCapture.capture(
                mode: contextAwareMode,
                documentBudget: modelManager.selectedModel.documentContextBudget
            )
            let tContextDone = Date()
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
                //
                // In audio-direct (Gemma/LiteRT) mode `stt` is nil — Gemma hears the
                // audio directly. Load a *display-only* STT so the user can still SEE
                // their words live; the answer is unchanged (audio-direct, below).
                let displaySTT: (any STTService)?
                if let stt {
                    displaySTT = stt
                } else {
                    displaySTT = try? await makeSttServiceForFile()
                }

                let lastTranscription: String
                if let displaySTT {
                    lastTranscription = await runStreamingTranscription(
                        session: session,
                        stt: displaySTT,
                        onTextUpdate: { [weak self] text in
                            self?.liveTranscriptionText = text
                        }
                    )
                } else {
                    // No STT available at all — wait for silence detection manually.
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
                tRecordStop = Date()
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

                // Command routing (see docs/SPEECH_AND_AI_DESIGN.md):
                //  - Case B: audio-capable model AND no STT loaded -> audio-direct.
                //    The model hears the audio; the NOOP system-prompt gate (added to
                //    `prompt` below) refuses empty commands.
                //  - Case A: otherwise -> text path. Use the STT transcript as the
                //    command, gated by the word-count check below. This applies even to
                //    Gemma when an STT is loaded, so the model receives explicit text and
                //    can never echo the screen.
                let audioDirectMode = (llm as? RoutedLLMService)?.supportsAudioInput == true && displaySTT == nil

                let command: String
                if audioDirectMode {
                    // The model will hear the voice instruction directly from the audio.
                    command = "[voice instruction]"
                } else if !lastTranscription.isEmpty {
                    // Transcript already produced live by the display STT during recording.
                    command = lastTranscription
                } else if let displaySTT {
                    state = .transcribing
                    command = (try? await displaySTT.transcribe(samples: samples)) ?? ""
                } else {
                    command = ""
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
                tCommandReady = Date()

                let draftMode = selectedText.isEmpty || DraftDetector.isDraftCommand(trimmedCommand)

                // Clear stale multi-turn context when the user has selected new text.
                if !selectedText.isEmpty { lastEditContext = nil }

                if let llm = self.llm {
                    // Phase 3: LLM generation
                    state = .generating

                    let family = modelManager.selectedModel.family
                    var prompt: String
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

                    // No-STT fallback gate (Case B in docs/SPEECH_AND_AI_DESIGN.md):
                    // with no STT there is no transcript to check, so in this single
                    // call we instruct the model to refuse an empty command. The output
                    // is checked for the NOOP sentinel below; if seen, we do nothing.
                    let noSTTAudioGate = audioDirectMode && displaySTT == nil
                    if noSTTAudioGate {
                        prompt += "\n\nIf the audio contains no clear spoken instruction, reply with exactly NOOP and nothing else. Never describe or transcribe the screen."
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
                        guard visionEnabled, self.modelManager.selectedModel.isVLM,
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
                        if tFirstToken == nil { tFirstToken = Date() }
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
                            raw.reserveCapacity(4096)
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
                    tGenDone = Date()

                    // No-STT gate result: the model signalled there was no real command
                    // (NOOP sentinel, or empty output). Do nothing — never paste/display.
                    if noSTTAudioGate {
                        let sentinel = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        if sentinel.isEmpty || sentinel.hasPrefix("NOOP") {
                            if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
                            streamingLLMText = ""
                            state = .idle
                            voiceEditTask = nil
                            return
                        }
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

                    try await presentOutput(cleaned, savedClipboard: savedClipboard, ttsStreamedAlready: willStreamTTS, targetIsEditable: targetIsEditable)
                    tInserted = Date()
                    lastEditContext = EditContext(instruction: trimmedCommand, result: cleaned, timestamp: Date())
                    SoundPlayer.shared.playCompletion()
                    // Capture the exact context the model saw (Sendable values only) so the
                    // log is falsifiable. See docs/SPEECH_AND_AI_DESIGN.md.
                    let logApp = NSWorkspace.shared.frontmostApplication?.localizedName
                    let logModelName = modelManager.selectedModel.name
                    let logBackend = modelManager.selectedModel.backendType == .liteRT ? "litert" : "mlx"
                    let logCtxMode = contextAwareMode.rawValue
                    let logCtxSource = screenContext.source.rawValue
                    let logCtxText = screenContext.promptBlock
                    let logHadShot = !vlmImages.isEmpty
                    // Latency split (milliseconds). nil for any phase that did not run.
                    func ms(_ a: Date?, _ b: Date?) -> Int? {
                        guard let a, let b else { return nil }
                        return Int(b.timeIntervalSince(a) * 1000)
                    }
                    let latContext = ms(tStart, tContextDone)
                    let latStt = ms(tRecordStop, tCommandReady)
                    let latFirstToken = ms(tCommandReady, tFirstToken)
                    let latModel = ms(tCommandReady, tGenDone)
                    let latInsert = ms(tGenDone, tInserted)
                    let latTotal = ms(tStart, tInserted)
                    Task.detached {
                        await TranscriptionStore.shared.save(
                            mode: .voiceEdit,
                            transcription: trimmedCommand,
                            llmResponse: cleaned,
                            activeApp: logApp,
                            modelName: logModelName,
                            modelBackend: logBackend,
                            contextMode: logCtxMode,
                            contextSource: logCtxSource,
                            contextText: logCtxText,
                            hadScreenshot: logHadShot,
                            latencyContextMs: latContext,
                            latencySttMs: latStt,
                            latencyFirstTokenMs: latFirstToken,
                            latencyModelMs: latModel,
                            latencyInsertMs: latInsert,
                            latencyTotalMs: latTotal
                        )
                    }
                    modelManager.keepAlive()
                    if stt != nil { modelManager.keepSTTAlive() }
                } else {
                    // STT-only mode (None selected): paste raw transcript directly
                    try await presentOutput(trimmedCommand, savedClipboard: savedClipboard, targetIsEditable: targetIsEditable)
                    SoundPlayer.shared.playCompletion()
                    let sttLogApp = NSWorkspace.shared.frontmostApplication?.localizedName
                    Task.detached {
                        await TranscriptionStore.shared.save(
                            mode: .voiceEdit,
                            transcription: trimmedCommand,
                            activeApp: sttLogApp
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
                // Capture main-actor state before detaching.
                let logApp = NSWorkspace.shared.frontmostApplication?.localizedName
                let logModelName = modelManager.selectedModel.name
                Task.detached {
                    await TranscriptionStore.shared.save(
                        mode: .grammarFix,
                        transcription: selectedText,
                        llmResponse: cleaned,
                        activeApp: logApp,
                        modelName: logModelName
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
        ttsStreamedAlready: Bool = false,
        targetIsEditable: Bool? = nil
    ) async throws {
        // `isEditable` now means "there is a text caret at the focus" (see
        // AXEditabilityDetector). Caret present → paste there; no caret → display.
        let isEditable = targetIsEditable ?? editabilityDetector.focusedElementIsEditable()
        if !useDisplayMode || isEditable {
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
            // DisplayResultController owns the TTS-then-auto-dismiss sequence.
            display.show(text, ttsStreamedAlready: ttsStreamedAlready)
            state = .idle
            if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
        }
    }

    // MARK: - Display-mode forwarders (logic lives in DisplayResultController)

    func readAloud(_ text: String) { display.readAloud(text) }

    func stopReadAloud() { display.stopReadAloud() }

    func scheduleDisplayAutoDismiss(after seconds: Double = 40) {
        display.scheduleAutoDismiss(after: seconds)
    }

    func keepDisplayResultAlive(_ hovering: Bool) { display.keepAlive(hovering) }

    /// Dismisses the display-mode overlay and stops TTS playback (called by Esc key handler).
    func clearDisplayModeResult() { display.clear() }

    // MARK: - Helpers

    // Service factories live in ModelSessionController — thin forwarders keep call sites unchanged.

    func makeSttService() async throws -> (any STTService)? {
        try await models.makeSttService()
    }

    func makeSttServiceForFile() async throws -> (any STTService)? {
        try await models.makeSttServiceForFile()
    }

    /// Runs the loaded LLM to rewrite `text` per a natural-language `instruction`.
    /// Used by the Transcribe window's "Edit with Voice" — no screen context, no paste,
    /// no overlay state changes. Loads the selected LLM from cache if it was offloaded.
    func editText(_ text: String, instruction: String) async throws -> String {
        if llm == nil, !modelManager.selectedModel.isNone {
            try await modelManager.loadModel(modelManager.selectedModel)
            if modelManager.inferenceRouter.isLoaded { llm = makeLLMService() }
            modelManager.keepAlive()
        }
        guard let llm else { throw VoiceEditorError.modelsNotLoaded }
        let family = modelManager.selectedModel.family
        let prompt = family.editPrompt(text: text, instruction: instruction, context: nil)
        let maxTokens = family.editMaxTokens(for: text)
        var raw = ""
        do {
            for try await chunk in llm.generateStream(prompt: prompt, images: [], maxTokens: maxTokens) {
                raw += chunk
            }
        } catch {
            let desc = "\(error)"
            if desc.localizedCaseInsensitiveContains("too long")
                || desc.localizedCaseInsensitiveContains("INVALID_ARGUMENT")
                || desc.localizedCaseInsensitiveContains("maximum number of tokens") {
                throw TextEditError.textTooLong
            }
            throw error
        }
        modelManager.keepAlive()
        return OutputCleaner.clean(family.postProcess(raw))
    }

    /// Records a spoken command (until silence) and transcribes it with the current
    /// STT. Backs the "Edit with Voice" mic in the Transcribe window.
    func dictateCommand() async throws -> String {
        guard let stt = try await makeSttServiceForFile() else {
            throw FileTranscriptionError.noTranscriptionModel
        }
        let samples = try await audioCapture.recordUntilSilence(vadDetector: modelManager.vadDetector)
        guard !samples.isEmpty else { return "" }
        return try await stt.transcribe(samples: samples)
    }

    /// Whether the *selected* LLM can transcribe audio (Gemma 4 family). Used to
    /// offer "transcribe with the AI model" in the Transcribe window. Works without
    /// the model being loaded (checks the backend type).
    var selectedLLMSupportsAudio: Bool {
        modelManager.selectedModel.backendType == .liteRT
    }

    func makeLLMTranscriptionSTT() async throws -> (any STTService)? {
        try await models.makeLLMTranscriptionSTT()
    }

    func rebuildLLMServiceIfNeeded() { models.rebuildLLMServiceIfNeeded() }

    func makeLLMService() -> RoutedLLMService { models.makeLLMService() }

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
