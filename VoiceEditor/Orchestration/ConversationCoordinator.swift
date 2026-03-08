import Combine
import SwiftUI

@MainActor
final class ConversationCoordinator: ObservableObject {
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
    private let dictationOverlay = DictationOverlayPanel()

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
        case .idle: return Image(systemName: "text.bubble")
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
        do {
            try await modelManager.loadAll()

            if let container = modelManager.modelContainer {
                llm = MLXLLMService(container: container)
            }
            if let models = modelManager.asrModels {
                stt = try await FluidAudioSTT(models: models)
            }

            state = .warmingUp
            try await llm?.warmup()

            state = .idle
            setupHotkeys()

            // Audio cue: setup complete
            SoundPlayer.shared.play(.glass)
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    func setupHotkeys() {
        guard permissions.accessibilityGranted, hotkeyManager == nil else { return }
        hotkeyManager = HotkeyManager(coordinator: self)
    }

    // MARK: - Model Switching

    func switchModel() async {
        guard state == .idle else { return }

        state = .downloading(progress: 0)
        do {
            try await modelManager.reloadLLM()

            if let container = modelManager.modelContainer {
                llm = MLXLLMService(container: container)
            }

            state = .warmingUp
            try await llm?.warmup()

            state = .idle
            SoundPlayer.shared.play(.glass)
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    // MARK: - Voice Edit

    func handleVoiceEdit() async {
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

        var savedClipboard: TextCaptureService.ClipboardSnapshot?

        do {
            savedClipboard = textCapture.saveClipboard()
            let selectedText = try await textCapture.captureSelectedText()

            // Phase 1: Record with live waveform + streaming transcription
            SoundPlayer.shared.play(.tink)
            state = .listening

            let session = try audioCapture.startContinuousRecording()
            dictationOverlay.show(text: "Listening...")
            dictationOverlay.startLevelPolling(session: session)

            // Streaming transcription loop — shows live text while recording
            var lastTranscription = ""
            while true {
                try? await Task.sleep(for: .milliseconds(300))

                if session.isSilenceDetected { break }

                let count = session.audioBuffer.count
                guard count >= 16_000 else { continue }

                let partial = session.audioBuffer.getPrefix(count)
                if let text = try? await stt.transcribe(samples: partial) {
                    lastTranscription = text
                    dictationOverlay.show(text: text)
                }
            }

            session.stop()

            // Phase 2: Final transcription on complete buffer
            state = .transcribing
            dictationOverlay.show(text: "Transcribing...")

            let samples = session.audioBuffer.getAll()
            guard samples.count >= 16_000 else {
                dictationOverlay.hide()
                throw VoiceEditorError.emptyTranscription
            }

            let command: String
            if let final = try? await stt.transcribe(samples: samples) {
                command = final
            } else {
                command = lastTranscription
            }

            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else {
                dictationOverlay.hide()
                throw VoiceEditorError.emptyTranscription
            }

            let draftMode = selectedText.isEmpty || DraftDetector.isDraftCommand(trimmedCommand)

            // Phase 3: LLM generation
            state = .generating
            dictationOverlay.show(text: "Generating...")

            let prompt: String
            let maxTokens: Int

            if draftMode {
                prompt = Prompts.draft(instruction: trimmedCommand)
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
            dictationOverlay.show(text: "Pasting...")
            try await textCapture.pasteText(cleaned)

            // Audio cue: done
            SoundPlayer.shared.play(.pop)
            dictationOverlay.hide()

            if let saved = savedClipboard {
                // Small delay before restore so paste completes
                try? await Task.sleep(for: .milliseconds(100))
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
            SoundPlayer.shared.play(.tink)

            state = .generating
            dictationOverlay.show(text: "Fixing grammar...")

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
            dictationOverlay.show(text: "Pasting...")
            try await textCapture.pasteText(cleaned)

            // Audio cue: done
            SoundPlayer.shared.play(.pop)
            dictationOverlay.hide()

            if let saved = savedClipboard {
                try? await Task.sleep(for: .milliseconds(100))
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
            let session = try audioCapture.startContinuousRecording()
            dictationSession = session

            SoundPlayer.shared.play(.tink)
            state = .dictating("")
            dictationOverlay.show(text: "Dictating...")
            dictationOverlay.startLevelPolling(session: session)

            // Streaming loop: re-transcribe the growing buffer every 300ms
            // and auto-stop when silence is detected after speech.
            streamingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { break }

                    // Auto-stop on silence — spawn a fresh task so
                    // stopDictation() doesn't run in a cancelled context.
                    if session.isSilenceDetected {
                        Task { @MainActor [weak self] in
                            await self?.stopDictation()
                        }
                        return
                    }

                    let count = session.audioBuffer.count
                    guard count >= 16_000 else { continue } // need ≥1s of audio

                    let samples = session.audioBuffer.getPrefix(count)
                    do {
                        let text = try await stt.transcribe(samples: samples)
                        await MainActor.run { self?.updateDictationText(text) }
                    } catch {
                        // Low confidence / short audio — silently skip this tick
                        continue
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
            let display = text.isEmpty ? "Dictating..." : text
            dictationOverlay.show(text: display)
        }
    }

    private func stopDictation() async {
        streamingTask?.cancel()
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
            SoundPlayer.shared.play(.pop)
            dictationOverlay.hide()
            state = .idle
            return
        }

        do {
            state = .transcribing
            dictationOverlay.show(text: "Finalizing...")

            let text = try await stt.transcribe(samples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                dictationOverlay.hide()
                state = .idle
                return
            }

            state = .pasting
            let savedClipboard = textCapture.saveClipboard()
            try await textCapture.pasteText(trimmed)

            SoundPlayer.shared.play(.pop)
            dictationOverlay.hide()

            try? await Task.sleep(for: .milliseconds(100))
            textCapture.restoreClipboard(savedClipboard)

            state = .idle
        } catch {
            dictationOverlay.hide()
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }

    // MARK: - Helpers

    private func resetErrorAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}
