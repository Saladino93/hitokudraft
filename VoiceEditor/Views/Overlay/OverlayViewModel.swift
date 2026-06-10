import AppKit
import SwiftUI
import Observation

/// Drives the overlay pill by deriving `OverlayState` from the coordinator's
/// observable properties. Views observe this ViewModel — never the coordinator directly.
@MainActor
@Observable
final class OverlayViewModel {

    // MARK: - Observable State

    /// The current overlay state. `nil` = overlay is hidden.
    /// The didSet drives DictationOverlayPanel (an AppKit controller, not a View).
    var overlayState: OverlayState? {
        didSet { onOverlayStateChange?(overlayState) }
    }

    /// Normalized audio level [0, 1] for waveform animation.
    var audioLevel: CGFloat = 0

    /// True when displaying a non-editable result (enables Esc dismissal + copy button).
    var isDisplayMode = false

    /// Number of lines needed for display-mode content (3–10).
    var displayModeMaxLines: Int = 3

    // Waveform animation is driven by WaveformBarsView's own timer (not here)
    // to avoid re-rendering the entire overlay 30 times per second.

    // MARK: - Internal

    /// AppKit hook for panel show/hide/resize — set by DictationOverlayPanel.observe.
    @ObservationIgnored var onOverlayStateChange: ((OverlayState?) -> Void)?

    @ObservationIgnored weak var coordinator: ConversationCoordinator?
    @ObservationIgnored private var pollingTimer: Timer?
    @ObservationIgnored private weak var audioSession: AudioCaptureService.ContinuousSession?
    @ObservationIgnored private var lastTranscription = ""
    /// Last seen displayModeResult — gates the line-count recalculation.
    @ObservationIgnored private var lastDisplayResult = ""
    /// Invalidates a previous observation loop when observe() is called again.
    @ObservationIgnored private var observationGeneration = 0
    /// Debounce timer for speaking → done transition (prevents flashing between TTS sentences).
    @ObservationIgnored private var speakingDebounceTask: Task<Void, Never>?

    // MARK: - TTS progress cache
    // deriveState() runs on every published change; without a memo the O(n) substring
    // search re-runs per change. The anchor keeps the search monotonic so repeated
    // sentences advance instead of snapping back to the first occurrence.
    @ObservationIgnored private var progressText = ""
    @ObservationIgnored private var progressSegment = ""
    @ObservationIgnored private var progressValue: Double = 0
    @ObservationIgnored private var progressAnchor: String.Index?

    // MARK: - Observe Coordinator

    func observe(_ coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        observationGeneration &+= 1
        let generation = observationGeneration

        // IMPORTANT: withObservationTracking's onChange fires on willSet — BEFORE the
        // property is updated. ObservationLoop defers the handler one main-actor turn
        // so handleCoordinatorChange() reads post-change values. (The old Combine
        // pipeline needed .receive(on: RunLoop.main) for the same reason.)
        handleCoordinatorChange()
        ObservationLoop.track(
            isActive: { [weak self] in self?.observationGeneration == generation },
            reading: { [weak self] in
                guard let c = self?.coordinator else { return }
                _ = c.state
                _ = c.liveTranscriptionText
                _ = c.streamingLLMText
                _ = c.displayModeResult
                _ = c.activeRecordingSession
                _ = c.ttsSpeakingSegment
            },
            onChange: { [weak self] in self?.handleCoordinatorChange() }
        )
    }

    /// Unified change handler — the per-publisher side effects from the old Combine
    /// sinks, made idempotent because observation tracking doesn't say *which*
    /// property changed.
    private func handleCoordinatorChange() {
        guard let coordinator else { return }

        // Live transcription bookkeeping (was the $liveTranscriptionText sink)
        let live = coordinator.liveTranscriptionText
        if !live.isEmpty { lastTranscription = live }

        // Display mode bookkeeping (was the $displayModeResult sink) — gated so
        // calculateLinesNeeded only runs when the text actually changed.
        let display = coordinator.displayModeResult
        if display != lastDisplayResult {
            lastDisplayResult = display
            if display.isEmpty {
                isDisplayMode = false
                displayModeMaxLines = 3
            } else {
                isDisplayMode = true
                displayModeMaxLines = calculateLinesNeeded(for: display)
            }
        }

        // Recording session → audio-level polling (was the $activeRecordingSession sink)
        if let session = coordinator.activeRecordingSession {
            if audioSession !== session { startPolling(session: session) }
        } else if audioSession != nil || pollingTimer != nil {
            stopPolling()
        }

        deriveState()
    }

    // MARK: - State Derivation

    private func deriveState() {
        guard let coordinator else {
            overlayState = nil
            return
        }

        let state = coordinator.state
        let displayResult = coordinator.displayModeResult
        let speakingSegment = coordinator.ttsSpeakingSegment
        let liveText = coordinator.liveTranscriptionText
        let streamText = coordinator.streamingLLMText

        // Display mode takes priority (result shown in overlay)
        if !displayResult.isEmpty {
            if !speakingSegment.isEmpty {
                // TTS is actively speaking
                speakingDebounceTask?.cancel()
                speakingDebounceTask = nil
                // Progress based on character position of the current segment in the full text.
                let progress = ttsProgress(text: displayResult, segment: speakingSegment)
                overlayState = .speaking(
                    text: displayResult,
                    currentSentence: speakingSegment,
                    progress: progress
                )
            } else if case .speaking = overlayState {
                // TTS segment went empty — debounce before transitioning to .done
                // (prevents flashing between sentences)
                if speakingDebounceTask == nil {
                    speakingDebounceTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        self?.overlayState = .done(text: displayResult)
                        self?.speakingDebounceTask = nil
                    }
                }
            } else {
                overlayState = .done(text: displayResult)
            }
            return
        }

        // Pipeline states
        switch state {
        case .listening:
            lastTranscription = liveText.isEmpty ? lastTranscription : liveText
            overlayState = .listening(transcription: liveText)

        case .dictating(let text):
            overlayState = .listening(transcription: text)

        case .transcribing:
            // Keep showing last transcription text during final STT pass.
            // Also covers Action Mode: transcript appears after recording,
            // persists while LLM routes the action.
            if !liveText.isEmpty {
                overlayState = .listening(transcription: liveText)
            } else {
                overlayState = .listening(transcription: lastTranscription)
            }

        case .generating:
            let streamingEnabled = (UserDefaults.standard.object(forKey: "showLLMStreamingInOverlay") as? Bool) ?? true
            if streamingEnabled && !streamText.isEmpty {
                overlayState = .generating(text: streamText)
            } else {
                overlayState = .generating(text: "")
            }

        case .pasting:
            // Brief flash — keep generating state appearance
            if case .generating = overlayState { /* keep */ } else {
                overlayState = nil
            }

        case .idle, .error, .downloading, .warmingUp:
            // Keep overlay visible if there's still live text (Action Mode routing phase)
            if !liveText.isEmpty {
                overlayState = .listening(transcription: liveText)
            } else if overlayState != nil && displayResult.isEmpty {
                overlayState = nil
                lastTranscription = ""
            }
        }
    }

    /// Character-position progress of `segment` within `text`, memoized per
    /// (text, segment) pair and searched forward from the previous segment's start.
    private func ttsProgress(text: String, segment: String) -> Double {
        guard !text.isEmpty else { return 0 }
        if text == progressText && segment == progressSegment { return progressValue }
        if text != progressText {
            progressText = text
            progressAnchor = nil
        }
        progressSegment = segment
        let start = progressAnchor ?? text.startIndex
        // Search from the current anchor first; fall back to a full scan in case
        // TTS restarted or segments arrived out of order.
        let range = text.range(of: segment, options: .literal, range: start..<text.endIndex)
            ?? text.range(of: segment, options: .literal)
        if let range {
            progressAnchor = range.lowerBound
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
            progressValue = Double(endOffset) / Double(text.count)
        } else {
            progressValue = 0
        }
        return progressValue
    }

    // MARK: - Audio Level Polling

    func startPolling(session: AudioCaptureService.ContinuousSession) {
        stopPolling()
        audioSession = session
        // Scheduled from the main actor, so the timer fires on the main run loop —
        // assumeIsolated avoids allocating a throwaway Task 30× per second.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollLevel()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        audioSession = nil
        audioLevel = 0
    }

    private func pollLevel() {
        guard let session = audioSession else { return }
        let raw = CGFloat(session.audioLevel)
        // Exponential smoothing
        let alpha: CGFloat = 0.3
        let smoothed = audioLevel + alpha * (raw - audioLevel)
        audioLevel = max(0, min(1, smoothed))
    }

    // MARK: - Helpers

    private func calculateLinesNeeded(for text: String) -> Int {
        let font = NSFont.systemFont(ofSize: 15)
        let width = (UserDefaults.standard.object(forKey: "overlayWidth") as? Double) ?? 350.0
        let textWidth = width - 70 // padding + indicator
        let size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        let lines = Int(ceil(rect.height / lineHeight))
        return max(3, min(lines, 10))
    }
}
