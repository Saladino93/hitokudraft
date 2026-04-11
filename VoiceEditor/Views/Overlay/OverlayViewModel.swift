import AppKit
import Combine
import SwiftUI

/// Drives the overlay pill by deriving `OverlayState` from the coordinator's
/// published properties. Views observe this ViewModel — never the coordinator directly.
@MainActor
final class OverlayViewModel: ObservableObject {

    // MARK: - Published State

    /// The current overlay state. `nil` = overlay is hidden.
    @Published var overlayState: OverlayState?

    /// Normalized audio level [0, 1] for waveform animation.
    @Published var audioLevel: CGFloat = 0

    /// True when displaying a non-editable result (enables Esc dismissal + copy button).
    @Published var isDisplayMode = false

    /// Number of lines needed for display-mode content (3–10).
    @Published var displayModeMaxLines: Int = 3

    /// Fires every ~33ms to drive waveform animation.
    @Published var tick = Date()

    // MARK: - Internal

    weak var coordinator: ConversationCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var pollingTimer: Timer?
    private weak var audioSession: AudioCaptureService.ContinuousSession?
    private var lastTranscription = ""
    /// Debounce timer for speaking → done transition (prevents flashing between TTS sentences).
    private var speakingDebounceTask: Task<Void, Never>?

    // MARK: - Observe Coordinator

    func observe(_ coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        cancellables.removeAll()

        // Merge all relevant signals into a single state derivation.
        // We subscribe to each property individually and call deriveState() on any change.

        coordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.deriveState() }
            .store(in: &cancellables)

        coordinator.$liveTranscriptionText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                if !text.isEmpty { self?.lastTranscription = text }
                self?.deriveState()
            }
            .store(in: &cancellables)

        coordinator.$streamingLLMText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.deriveState() }
            .store(in: &cancellables)

        coordinator.$displayModeResult
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if text.isEmpty {
                    self.isDisplayMode = false
                    self.displayModeMaxLines = 3
                } else {
                    self.isDisplayMode = true
                    self.displayModeMaxLines = self.calculateLinesNeeded(for: text)
                }
                self.deriveState()
            }
            .store(in: &cancellables)

        coordinator.$activeRecordingSession
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                if let session {
                    self.startPolling(session: session)
                } else {
                    self.stopPolling()
                }
            }
            .store(in: &cancellables)

        coordinator.$ttsSpeakingSegment
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.deriveState() }
            .store(in: &cancellables)
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
                let sentences = displayResult.components(separatedBy: ". ")
                let currentIndex = sentences.firstIndex { $0.contains(speakingSegment) } ?? 0
                let progress = sentences.count > 1
                    ? Double(currentIndex) / Double(sentences.count - 1)
                    : 0.0
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
            // Keep showing last transcription text during final STT pass
            overlayState = .listening(transcription: lastTranscription)

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
            if overlayState != nil && displayResult.isEmpty {
                overlayState = nil
                lastTranscription = ""
            }
        }
    }

    // MARK: - Audio Level Polling

    func startPolling(session: AudioCaptureService.ContinuousSession) {
        stopPolling()
        audioSession = session
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        tick = Date()
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
