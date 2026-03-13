import AVFoundation
import Combine
import FluidAudio
import MLXAudioSTT
import MLXLMCommon
import os
import SwiftUI

@MainActor
final class ConversationCoordinator: ObservableObject {
    private nonisolated(unsafe) static let log = Logger(subsystem: "com.hitokudraft.coordinator", category: "pipeline")
    @Published private(set) var state: AppState = .idle

    let permissions = PermissionsCoordinator()
    let modelManager = ModelManager()

    private let textCapture = TextCaptureService()
    private let audioCapture = AudioCaptureService()
    private var stt: (any STTService)?
    private var llm: (any LLMService)?
    private var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var dictationSession: AudioCaptureService.ContinuousSession?
    private var streamingTask: Task<Void, Never>?
    private var voiceEditTask: Task<Void, Never>?
    private let dictationOverlay = DictationOverlayPanel()
    /// Last finalized text from a native streaming session (Qwen3-ASR).
    /// Set by `runStreamingTranscription` for `stopDictation()` to use.
    private var lastStreamingTranscription: String?

    /// Cancellable model-loading tasks so a new switch can abort an in-flight download.
    private var llmLoadTask: Task<Void, Never>?
    private var sttLoadTask: Task<Void, Never>?

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

    init() {
        // Forward child ObservableObject changes so SwiftUI re-renders
        permissions.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        modelManager.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Re-try hotkey registration when accessibility is granted later
        permissions.onAccessibilityGranted = { [weak self] in
            self?.setupHotkeys()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.setup() }
        }
    }

    // MARK: - Setup

    func setup() async {
        guard state == .idle else { return }
        state = .downloading(progress: 0)

        // Phase 1: LLM — wrapped in llmLoadTask so switchModel() can cancel it
        llmLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.loadModel(self.modelManager.selectedModel)
                try Task.checkCancellation()

                if let container = self.modelManager.modelContainer {
                    self.llm = self.makeLLMService(container: container)
                }

                self.state = .warmingUp
                try await self.llm?.warmup()
                try Task.checkCancellation()

                self.state = .idle
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.state = .idle       // switchModel() takes over for LLM
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                self.revertToLastLoadedModel()
                self.state = .error(error.localizedDescription)
                self.resetErrorAfterDelay()
            }
            self.llmLoadTask = nil
        }
        await llmLoadTask?.value

        // Phase 2: STT — always runs (independent of LLM choice)
        if stt == nil {
            do {
                try await modelManager.reloadSTT()
                stt = try await makeSttService()
                modelManager.sttReady = (stt != nil)
            } catch {
                // STT failure is non-fatal — log but don't block
                Self.log.error("STT setup failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        setupHotkeys()
        modelManager.statusMessage = ""
        await drainPendingSwitches()
    }

    func setupHotkeys() {
        guard permissions.accessibilityGranted, hotkeyManager == nil else { return }
        hotkeyManager = HotkeyManager(coordinator: self)
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
            do {
                try await self.modelManager.reloadLLM()
                try Task.checkCancellation()

                if let container = self.modelManager.modelContainer {
                    self.llm = self.makeLLMService(container: container)
                }

                self.state = .warmingUp
                try await self.llm?.warmup()
                try Task.checkCancellation()

                self.state = .idle
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                self.revertToLastLoadedModel()
                self.state = .error(error.localizedDescription)
                self.resetErrorAfterDelay()
            }
            self.llmLoadTask = nil
            await self.drainPendingSwitches()
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
            do {
                try await self.modelManager.loadModel(model)
                try Task.checkCancellation()

                // Download succeeded — add to registry with measured size
                var finalModel = model
                let measured = ModelRegistry.measureModelOnDisk(model)
                if measured > 0 { finalModel.estimatedMemoryGB = measured }
                ModelRegistry.addModel(finalModel)

                // Set as selected model — triggers onChange → switchModel() which
                // will early-return from reloadLLM() because loadedModelPath matches,
                // then redo makeLLMService + warmup (cheap, ~200ms)
                self.modelManager.selectedModel = finalModel
                UserDefaults.standard.set(finalModel.path, forKey: "selectedModelPath")

                if let container = self.modelManager.modelContainer {
                    self.llm = self.makeLLMService(container: container)
                }

                self.state = .warmingUp
                try await self.llm?.warmup()
                try Task.checkCancellation()

                self.state = .idle
                SoundPlayer.shared.play(.glass)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as URLError where error.code == .cancelled {
                self.state = .idle
            } catch {
                self.revertToLastLoadedModel()
                self.state = .error(error.localizedDescription)
                self.resetErrorAfterDelay()
            }
            self.llmLoadTask = nil
            await self.drainPendingSwitches()
        }
    }

    // MARK: - Voice Edit

    func handleVoiceEdit() async {
        // Toggle: pressing during recording cancels the voice edit
        if state == .listening {
            voiceEditTask?.cancel()
            voiceEditTask = nil
            return
        }

        guard state == .idle else { return }

        guard let stt else {
            state = .error(VoiceEditorError.modelsNotLoaded.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        guard let llm else {
            state = .error(VoiceEditorError.modelsNotLoaded.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        voiceEditTask = Task { [weak self] in
            guard let self else { return }

            var savedClipboard: TextCaptureService.ClipboardSnapshot?

            do {
                savedClipboard = textCapture.saveClipboard()
                let selectedText = try await textCapture.captureSelectedText()

                // Phase 1: Record with live waveform + streaming transcription
                SoundPlayer.shared.playActivation()
                state = .listening

                let session = try await audioCapture.startContinuousRecording()
                dictationOverlay.show(text: L("overlay.listening"))
                dictationOverlay.startLevelPolling(session: session)

                // Streaming transcription loop — shows live text while recording
                // Path A (legacy): 300ms re-transcription poll
                // Path B (native): Qwen3-ASR StreamingInferenceSession
                let lastTranscription = await runStreamingTranscription(
                    session: session,
                    onTextUpdate: { [dictationOverlay] text in
                        dictationOverlay.show(text: text)
                    }
                )

                // Check cancellation after recording phase
                guard !Task.isCancelled else {
                    session.stop()
                    dictationOverlay.hide()
                    if let saved = savedClipboard { textCapture.restoreClipboard(saved) }
                    state = .idle
                    voiceEditTask = nil
                    return
                }

                session.stop()

                let samples = session.audioBuffer.getAll()
                guard samples.count >= 16_000 else {
                    dictationOverlay.hide()
                    throw VoiceEditorError.emptyTranscription
                }

                // For native streaming, the session already finalized the text.
                // For legacy polling, do a final transcription on the complete buffer.
                let command: String
                if modelManager.selectedSTTModel.supportsNativeStreaming && !lastTranscription.isEmpty {
                    command = lastTranscription
                } else {
                    state = .transcribing
                    dictationOverlay.show(text: L("overlay.transcribing"))
                    do {
                        command = try await stt.transcribe(samples: samples)
                    } catch {
                        Self.log.error("Final transcription failed, falling back to streaming result: \(error.localizedDescription, privacy: .public)")
                        command = lastTranscription
                    }
                }

                let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCommand.isEmpty else {
                    dictationOverlay.hide()
                    throw VoiceEditorError.emptyTranscription
                }

                // Reject very short transcriptions that are likely noise/hallucinations
                let wordCount = trimmedCommand.split(separator: " ").count
                guard wordCount >= 2 else {
                    Self.log.warning("Transcription too short (\(wordCount) word): '\(trimmedCommand)' — likely noise")
                    dictationOverlay.hide()
                    throw VoiceEditorError.emptyTranscription
                }

                let draftMode = selectedText.isEmpty || DraftDetector.isDraftCommand(trimmedCommand)

                // Phase 3: LLM generation
                state = .generating
                dictationOverlay.show(text: L("overlay.generating"))

                let prompt: String
                let maxTokens: Int

                if draftMode {
                    if modelManager.selectedModel.useVoiceCleanPrompt {
                        prompt = Prompts.voiceCleanDraft(instruction: trimmedCommand)
                    } else {
                        prompt = Prompts.draft(instruction: trimmedCommand)
                    }
                    maxTokens = Prompts.draftMaxTokens
                } else {
                    prompt = Prompts.edit(text: selectedText, instruction: trimmedCommand)
                    maxTokens = Prompts.editMaxTokens(for: selectedText)
                }

                let result = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
                let cleaned = OutputCleaner.clean(result)

                guard !cleaned.isEmpty else {
                    dictationOverlay.hide()
                    throw VoiceEditorError.emptyOutput
                }

                state = .pasting
                dictationOverlay.show(text: L("overlay.pasting"))
                try await textCapture.pasteText(cleaned)

                // Audio cue: done
                SoundPlayer.shared.playCompletion()
                dictationOverlay.hide()

                if let saved = savedClipboard {
                    // Small delay before restore so paste completes
                    try? await Task.sleep(for: .milliseconds(300))
                    textCapture.restoreClipboard(saved)
                }

                state = .idle
                voiceEditTask = nil
            } catch {
                dictationOverlay.hide()
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
        guard state == .idle, let llm else { return }

        var savedClipboard: TextCaptureService.ClipboardSnapshot?

        do {
            savedClipboard = textCapture.saveClipboard()
            let selectedText = try await textCapture.captureSelectedText()

            guard !selectedText.isEmpty else {
                if let saved = savedClipboard {
                    textCapture.restoreClipboard(saved)
                }
                return
            }

            // Audio cue: start
            SoundPlayer.shared.playActivation()

            state = .generating
            dictationOverlay.show(text: L("overlay.fixing_grammar"))

            let lang = LanguageDetector.detect(selectedText)
            let instruction = Instructions.forLanguage(lang)
            let prompt = Prompts.edit(text: selectedText, instruction: instruction)
            let maxTokens = Prompts.editMaxTokens(for: selectedText)

            let result = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
            let cleaned = OutputCleaner.clean(result)

            guard !cleaned.isEmpty else {
                dictationOverlay.hide()
                throw VoiceEditorError.emptyOutput
            }

            state = .pasting
            dictationOverlay.show(text: L("overlay.pasting"))
            try await textCapture.pasteText(cleaned)

            // Audio cue: done
            SoundPlayer.shared.playCompletion()
            dictationOverlay.hide()

            if let saved = savedClipboard {
                try? await Task.sleep(for: .milliseconds(300))
                textCapture.restoreClipboard(saved)
            }

            state = .idle
        } catch {
            dictationOverlay.hide()
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

        guard state == .idle else { return }

        guard let stt else {
            state = .error(VoiceEditorError.modelsNotLoaded.localizedDescription)
            resetErrorAfterDelay()
            return
        }

        do {
            textCapture.rememberTargetApp()
            let session = try await audioCapture.startContinuousRecording()
            dictationSession = session

            SoundPlayer.shared.playActivation()
            state = .dictating("")
            dictationOverlay.show(text: L("overlay.dictating"))
            dictationOverlay.startLevelPolling(session: session)

            // Streaming loop — picks native streaming (Path B) or legacy poll (Path A)
            // and auto-stops when silence is detected after speech.
            streamingTask = Task { [weak self] in
                guard let self else { return }
                let finalText = await self.runStreamingTranscription(
                    session: session,
                    onTextUpdate: { [weak self] text in
                        self?.updateDictationText(text)
                    }
                )
                await MainActor.run { self.lastStreamingTranscription = finalText }

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
            let display = text.isEmpty ? L("overlay.dictating") : text
            dictationOverlay.show(text: display)
        }
    }

    private func stopDictation() async {
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
            dictationOverlay.hide()
            state = .idle
            return
        }
        dictationSession = nil
        session.stop()

        // Final transcription on the complete buffer
        let samples = session.audioBuffer.getAll()
        guard samples.count >= 16_000, let stt else {
            SoundPlayer.shared.playCompletion()
            dictationOverlay.hide()
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
                dictationOverlay.hide()
                state = .idle
                return
            }

            let savedClipboard = textCapture.saveClipboard()
            try await textCapture.pasteText(trimmed)

            SoundPlayer.shared.playCompletion()
            dictationOverlay.hide()

            try? await Task.sleep(for: .milliseconds(300))
            textCapture.restoreClipboard(savedClipboard)

            state = .idle
        } catch {
            dictationOverlay.hide()
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
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
        }
    }

    private var modelCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models")
    }

    private func makeLLMService(container: ModelContainer) -> MLXLLMService {
        let prompt = modelManager.selectedModel.useVoiceCleanPrompt
            ? Prompts.voiceCleanSystemPrompt
            : Prompts.systemPrompt
        return MLXLLMService(
            container: container,
            disableThinking: modelManager.selectedModel.disableThinking,
            systemPrompt: prompt
        )
    }

    /// Runs the appropriate streaming loop for the current STT backend.
    /// - **Path A** (legacy): 300ms re-transcription of the growing buffer
    /// - **Path B** (native): Qwen3-ASR `StreamingInferenceSession`
    ///
    /// Returns the final transcription text once silence is detected or the task is cancelled.
    private func runStreamingTranscription(
        session: AudioCaptureService.ContinuousSession,
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) async -> String {
        guard let stt else { return "" }

        // Path B: Native streaming for Qwen3-ASR
        if let mlxStt = stt as? MLXAudioSTTService,
           let streamSession = mlxStt.createStreamingSession() {

            // Shared state — written by event task, read after it completes
            nonisolated(unsafe) var lastConfirmed = ""

            // Event listener — updates overlay with confirmed + provisional text
            let eventTask = Task.detached {
                for await event in streamSession.events {
                    switch event {
                    case .displayUpdate(let confirmedText, let provisionalText):
                        let display = confirmedText + provisionalText
                        lastConfirmed = confirmedText
                        if !display.isEmpty {
                            await onTextUpdate(display)
                        }
                    case .ended(let fullText):
                        lastConfirmed = fullText
                    default:
                        break
                    }
                }
            }

            // Audio feed loop — polls buffer for new samples every 100ms
            var lastFedCount = 0
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled || session.isSilenceDetected { break }

                let currentCount = session.audioBuffer.count
                if currentCount > lastFedCount {
                    let newSamples = session.audioBuffer.getSuffix(from: lastFedCount)
                    streamSession.feedAudio(samples: newSamples)
                    lastFedCount = currentCount
                }
            }

            // Flush pending audio, promote provisional tokens, emit .ended
            streamSession.stop()
            // Race eventTask against a 30s timeout so a stalled MLX session can't hang forever
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await eventTask.value }
                group.addTask { try? await Task.sleep(for: .seconds(30)) }
                _ = await group.next()
                group.cancelAll()
            }
            return lastConfirmed
        }

        // Path A: Non-blocking polling for non-streaming models (e.g. ForcedAligner)
        // Transcription runs in a detached Task so the main loop keeps
        // checking silence every 200ms without blocking on inference.
        var lastTranscription = ""
        nonisolated(unsafe) var pendingText: String? = nil
        nonisolated(unsafe) var taskDone = false
        var transcriptionTask: Task<Void, Never>? = nil
        let logger = Self.log

        while true {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled || session.isSilenceDetected { break }

            // Harvest completed transcription result
            if taskDone {
                if let text = pendingText {
                    lastTranscription = text
                    await onTextUpdate(text)
                }
                pendingText = nil
                transcriptionTask = nil
                taskDone = false
            }

            // Launch new transcription if none in-flight and buffer has data
            if transcriptionTask == nil {
                let count = session.audioBuffer.count
                if count >= 16_000 {
                    let snapshot = session.audioBuffer.getPrefix(count)
                    let sttRef = stt
                    transcriptionTask = Task.detached {
                        do {
                            let text = try await sttRef.transcribe(samples: snapshot)
                            pendingText = text
                        } catch {
                            logger.error("Path A transcription: \(error.localizedDescription, privacy: .public)")
                        }
                        taskDone = true
                    }
                }
            }
        }

        // Wait for in-flight transcription (up to 45s) after silence detected
        if let task = transcriptionTask {
            logger.info("Waiting for in-flight transcription (up to 45s)")
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(45)) }
                _ = await group.next()
                group.cancelAll()
            }
            if let text = pendingText {
                lastTranscription = text
            }
        }

        return lastTranscription
    }

    private func resetErrorAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
                await drainPendingSwitches()
            }
        }
    }
}
