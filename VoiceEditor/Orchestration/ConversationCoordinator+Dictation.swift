import AppKit
import Foundation
import os

// MARK: - Dictation (start, stop, streaming loop)

extension ConversationCoordinator {

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
        modelManager.cancelSTTOffload()
        await TTSService.shared.stop()
        clearDisplayModeResult()

        // Dictation always needs STT. If not loaded (e.g. offloaded), reload now.
        if stt == nil {
            if modelManager.selectedSTTModel.isNone {
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

    func updateDictationText(_ text: String) {
        if case .dictating = state {
            state = .dictating(text)
        }
    }

    func stopDictation() async {
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

            let savedClipboardOpt: TextCaptureService.ClipboardSnapshot? = textCapture.saveClipboard()
            // Dictation always pastes the raw transcript — never shows in the overlay.
            try await presentOutput(finalText, savedClipboard: savedClipboardOpt, useDisplayMode: false)

            SoundPlayer.shared.playCompletion()
            Task.detached {
                await TranscriptionStore.shared.save(
                    mode: .dictation,
                    transcription: trimmed,
                    llmResponse: finalText != trimmed ? finalText : nil,
                    activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                    modelName: self.modelManager.selectedModel.name
                )
            }
            modelManager.keepAlive()
            modelManager.keepSTTAlive()
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
            resetErrorAfterDelay()
        }
    }
}
