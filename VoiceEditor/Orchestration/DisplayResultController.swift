import Foundation

/// Owns the overlay "display mode" lifecycle: the shown result text, TTS playback
/// (pre-streamed or synthesized on demand), the speaking-segment highlight, and the
/// hover-pausable auto-dismiss countdown.
///
/// Extracted from ConversationCoordinator (audit batch 4). The coordinator forwards
/// its public display API here, so views and OverlayViewModel are unchanged. This
/// controller never touches AppState — the coordinator owns pipeline state.
@MainActor
@Observable
final class DisplayResultController {

    /// Non-empty when the last result was displayed in the overlay instead of pasted
    /// (focused element was not editable). Auto-cleared after the dismiss countdown.
    var result: String = ""

    /// The TTS segment currently being spoken — used by the overlay to highlight text.
    var speakingSegment: String = ""

    /// Stateless UserDefaults wrapper — reads current TTS settings at call time.
    @ObservationIgnored private let preferences: PreferencesStore

    /// Owns the TTS playback phase for display-mode answers; cancelled early by clear().
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// Restartable auto-dismiss countdown, kept separate from `clearTask` so
    /// hovering the overlay can pause/reset it without disturbing TTS playback.
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init(preferences: PreferencesStore = PreferencesStore()) {
        self.preferences = preferences
    }

    // MARK: - Show (non-editable output path)

    /// Shows `text` in the overlay and starts the TTS-then-auto-dismiss sequence.
    /// `ttsStreamedAlready` means sentences were enqueued during generation — wait
    /// for the queue to drain instead of synthesizing the full text again.
    func show(_ text: String, ttsStreamedAlready: Bool) {
        result = text
        // Capture TTS settings synchronously before entering the Task closure.
        let tts = preferences.ttsSettings
        let ttsEnabled = tts.enabled
        let ttsBackend = tts.backend
        let ttsVoice = tts.voice
        let ttsSpeed = tts.speed
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            // TTS: if sentences were already streamed into the queue, wait for the
            // queue to drain. Otherwise synthesize the full text as a single utterance.
            // The auto-dismiss timer only starts after audio finishes (or immediately if TTS off).
            if ttsEnabled {
                // Ensure highlight callback is set for both paths.
                await TTSService.shared.setOnSegmentStart { [weak self] segment in
                    self?.speakingSegment = segment
                }
                if ttsStreamedAlready {
                    await TTSService.shared.waitForQueue()
                } else {
                    // Split into sentences for fast first-word playback.
                    for sentence in text.splitIntoSentences() {
                        await TTSService.shared.enqueue(
                            text: sentence, voice: ttsVoice, speed: ttsSpeed, backend: ttsBackend
                        )
                    }
                    await TTSService.shared.waitForQueue()
                }
            }
            guard !Task.isCancelled else { return }
            // Start the (hover-pausable) auto-dismiss countdown.
            self?.scheduleAutoDismiss()
            self?.clearTask = nil
        }
    }

    // MARK: - Read Aloud

    /// Reads text aloud using sentence-by-sentence streaming for low latency.
    /// Cancels and restarts the overlay auto-dismiss timer so it waits for TTS to finish.
    func readAloud(_ text: String) {
        let tts = preferences.ttsSettings
        let voice = tts.voice
        let speed = tts.speed
        let backend = tts.backend

        // Cancel the existing auto-dismiss timer — we'll restart it after TTS finishes.
        clearTask?.cancel()
        clearTask = nil

        // Split into sentences and enqueue for streaming playback.
        // First sentence plays while the rest are being synthesized.
        let sentences = text.splitIntoSentences()

        clearTask = Task { [weak self] in
            // Register segment callback for text highlighting in the overlay.
            await TTSService.shared.setOnSegmentStart { [weak self] segment in
                self?.speakingSegment = segment
            }

            // Enqueue all sentences — first one starts playing immediately.
            for sentence in sentences {
                await TTSService.shared.enqueue(
                    text: sentence, voice: voice, speed: speed, backend: backend
                )
            }

            // Wait for all sentences to finish playing.
            await TTSService.shared.waitForQueue()

            // Then start the (hover-pausable) auto-dismiss countdown.
            guard !Task.isCancelled else { return }
            self?.scheduleAutoDismiss()
            self?.clearTask = nil
        }
    }

    /// Stops TTS playback but keeps the result visible in the overlay.
    /// Wired to the overlay speaker→stop toggle so the user can silence playback
    /// without dismissing the text (unlike `clear()`, which is Esc).
    /// Restarts the auto-dismiss timer so the overlay still goes away on its own.
    func stopReadAloud() {
        // Cancel the in-flight read-aloud task (sentence enqueue + auto-dismiss wait).
        clearTask?.cancel()
        clearTask = nil
        speakingSegment = ""
        Task { await TTSService.shared.stop() }

        // Keep the text on screen, but restart the auto-dismiss countdown.
        scheduleAutoDismiss()
    }

    // MARK: - Auto-Dismiss

    /// (Re)starts the auto-dismiss countdown for a display-mode answer.
    /// Display-mode results (shown when there is no text cursor to paste into) stay on
    /// screen, then auto-close after `seconds` once the user is no longer attending to
    /// the overlay. The countdown is paused while the overlay is hovered or focused
    /// (see keepAlive), so a shown answer never vanishes while it is being read.
    /// Esc dismisses it anytime.
    func scheduleAutoDismiss(after seconds: Double = 40) {
        dismissTask?.cancel()
        guard !result.isEmpty else { dismissTask = nil; return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.result = ""
            self?.dismissTask = nil
        }
    }

    /// Keeps the overlay open while the cursor is over it; resumes the countdown
    /// when the cursor leaves. Wired to `.onHover` in the overlay content so a
    /// long answer never vanishes while the user is reading or scrolling it.
    func keepAlive(_ hovering: Bool) {
        guard !result.isEmpty else { return }
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleAutoDismiss()
        }
    }

    /// Dismisses the display-mode overlay and stops TTS playback (called by Esc key handler).
    func clear() {
        clearTask?.cancel()
        clearTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        result = ""
        speakingSegment = ""
        Task { await TTSService.shared.stop() }
    }
}
