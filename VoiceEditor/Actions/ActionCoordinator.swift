import Foundation

/// Orchestrates the Action Mode pipeline for Ctrl+A with no text selected:
///   listen → transcribe → route (LLM) → confirm → execute (EventKit)
///
/// This object owns EventKitService and borrows audio/STT/LLM infrastructure
/// via lazy closures — closures always return the coordinator's current values,
/// even after model switches or offloads.
///
/// State changes are reported via `onStateChange` so the existing
/// DictationOverlayPanel reacts automatically through its Combine subscriptions.
///
/// Removability: deleting VoiceEditor/Actions/ and the two wiring lines in
/// ConversationCoordinator.swift fully restores prior behavior.
@MainActor
final class ActionCoordinator {

    // MARK: - Injected dependencies (closures for always-current values)

    private weak var audioCapture: AudioCaptureService?
    private let getSTT: () -> (any STTService)?
    private let getLLM: () -> (any LLMService)?
    private let getVADDetector: () -> VoiceActivityDetector?

    // MARK: - Owned

    private let eventKit = EventKitService()

    // MARK: - Callbacks

    /// Called to update the host coordinator's `state` property.
    /// Drives the DictationOverlayPanel automatically.
    var onStateChange: ((AppState) -> Void)?

    /// Called to show/clear the transcript text in the overlay (via liveTranscriptionText).
    /// Pass "" to clear. Wired in ConversationCoordinator.setup().
    var setLiveTranscript: ((String) -> Void)?

    // MARK: - Init

    init(
        audioCapture: AudioCaptureService,
        getSTT: @escaping () -> (any STTService)?,
        getLLM: @escaping () -> (any LLMService)?,
        getVADDetector: @escaping () -> VoiceActivityDetector?
    ) {
        self.audioCapture = audioCapture
        self.getSTT = getSTT
        self.getLLM = getLLM
        self.getVADDetector = getVADDetector
    }

    // MARK: - Entry Point

    /// Called by ConversationCoordinator.handleGrammarFix() when no text is selected.
    /// Silently returns if STT or LLM are unavailable (mirrors grammar-fix's silent no-op).
    func handle() async {
        guard let audioCapture else { return }
        guard let stt = getSTT() else { return }
        guard let llm = getLLM() else { return }  // Action Mode requires LLM for routing

        // Phase 1: Listen
        SoundPlayer.shared.playActivation()
        onStateChange?(.listening)

        let samples: [Float]
        do {
            samples = try await audioCapture.recordUntilSilence(
                vadDetector: getVADDetector()
            )
        } catch {
            // No speech, mic error, etc. — silent return
            onStateChange?(.idle)
            return
        }

        // Phase 2: Transcribe
        onStateChange?(.transcribing)
        let transcript: String
        do {
            transcript = try await stt.transcribe(samples: samples)
        } catch {
            onStateChange?(.idle)
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onStateChange?(.idle)
            return
        }

        // Show transcript in overlay so user sees what was heard
        setLiveTranscript?(trimmed)

        // Phase 3: Route via LLM
        onStateChange?(.generating)
        let action: PendingAction
        do {
            action = try await ActionRouter.route(transcript: trimmed, llm: llm)
        } catch {
            onStateChange?(.error(error.localizedDescription))
            return
        }

        // Return to idle and clear transcript BEFORE showing the modal
        setLiveTranscript?("")
        onStateChange?(.idle)

        // Phase 4: Confirm (always required — never fire-and-forget)
        guard ActionConfirmationPanel.confirm(action) else { return }

        // Phase 5: Execute
        do {
            try await execute(action)
            SoundPlayer.shared.playCompletion()
        } catch {
            onStateChange?(.error(error.localizedDescription))
        }
    }

    // MARK: - Execute

    private func execute(_ action: PendingAction) async throws {
        switch action {
        case .calendarEvent(let e):
            let permission = await eventKit.requestCalendarAccess()
            guard permission == .granted else {
                throw EventKitService.EventKitError.accessDenied("Calendar access denied")
            }
            try await eventKit.createCalendarEvent(e)

        case .reminder(let r):
            let permission = await eventKit.requestRemindersAccess()
            guard permission == .granted else {
                throw EventKitService.EventKitError.accessDenied("Reminders access denied")
            }
            try await eventKit.createReminder(r)

        case .unknown:
            break  // confirm() returns false for .unknown; should not reach here
        }
    }
}
