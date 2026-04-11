import AppKit
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

    /// Called to show a result in the display-mode overlay (e.g. web search results).
    var onDisplayResult: ((String) -> Void)?

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
        let llm = getLLM()
        guard llm != nil else { return }  // Action Mode requires LLM for routing
        // STT can be nil when LiteRT is active (Gemma handles audio natively)
        let stt = getSTT()

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

        // Phase 2: Transcribe (STT if available, otherwise Gemma via audio-direct)
        onStateChange?(.transcribing)
        let transcript: String
        if let stt {
            do {
                transcript = try await stt.transcribe(samples: samples)
            } catch {
                onStateChange?(.idle)
                return
            }
        } else if let routedLLM = llm as? RoutedLLMService, routedLLM.supportsAudioInput {
            // LiteRT path: Gemma transcribes the audio natively
            do {
                let audioData = AudioEncoder.wavData(from: samples)
                var raw = ""
                for try await chunk in routedLLM.generateStream(
                    prompt: "Transcribe this audio exactly as spoken. Output only the transcription.",
                    audio: audioData, maxTokens: 200
                ) { raw += chunk }
                transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                onStateChange?(.idle)
                return
            }
        } else {
            onStateChange?(.idle)
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onStateChange?(.idle)
            return
        }

        // Show transcript in overlay — stays visible while LLM routes
        // (no .generating state change here: that would overwrite the transcript text)
        setLiveTranscript?(trimmed)

        // Phase 3: Route via LLM
        var action: PendingAction
        do {
            action = try await ActionRouter.route(transcript: trimmed, llm: llm!)
        } catch {
            setLiveTranscript?("")
            onStateChange?(.error(error.localizedDescription))
            return
        }

        // Return to idle and clear transcript BEFORE showing the modal
        setLiveTranscript?("")
        onStateChange?(.idle)

        // Phase 4: Confirm (always required — never fire-and-forget)
        // Must run on MainActor for NSAlert.runModal()
        guard await ActionConfirmationPanel.confirm(action) else { return }

        // Phase 5: Execute
        do {
            try await execute(action)
            SoundPlayer.shared.playCompletion()
            Task.detached {
                await TranscriptionStore.shared.save(
                    mode: .action,
                    transcription: trimmed,
                    llmResponse: String(describing: action),
                    activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
                )
            }
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

        case .note(let n):
            try await NoteService.createNote(title: n.title, body: n.body)

        case .timer(let t):
            try await TimerService.setTimer(durationSeconds: t.durationSeconds, label: t.label)

        case .email(let e):
            try EmailService.composeEmail(subject: e.subject, body: e.body)

        case .webSearch(let s):
            let internetEnabled = UserDefaults.standard.bool(forKey: "internetAccessEnabled")
            guard internetEnabled else {
                throw NSError(domain: "ActionCoordinator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Internet access is disabled in Settings."])
            }
            guard let llm = getLLM() else {
                throw NSError(domain: "ActionCoordinator", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No LLM loaded for summarizing results."])
            }
            onStateChange?(.generating)
            defer { onStateChange?(.idle) }
            let searchService = DuckDuckGoSearchService()
            let results = try await searchService.search(query: s.query, maxResults: 4)
            guard !results.isEmpty else {
                onDisplayResult?("No results found for \"\(s.query)\".")
                return
            }
            // Feed results to LLM for a natural summary with sources.
            let context = results.enumerated().map { i, r in
                "[\(i + 1)] \(r.title)\n\(r.snippet)\nURL: \(r.url?.absoluteString ?? "N/A")"
            }.joined(separator: "\n\n")
            let summarizePrompt = """
            Based on these web search results for "\(s.query)", write a concise, natural answer. \
            Cite sources as [1], [2], etc. Keep it brief (3-5 sentences max). \
            Do not invent information beyond what the sources provide.

            Search results:
            \(context)

            Answer:
            """
            let answer = try await llm.generate(prompt: summarizePrompt, maxTokens: 300)
            let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            // Append source list so [1], [2] references are meaningful.
            let sources = results.enumerated().map { i, r in
                "[\(i + 1)] \(r.url?.host ?? r.title)"
            }.joined(separator: "\n")
            onDisplayResult?(cleaned + "\n\n" + sources)

        case .calendarQuery(let q):
            guard let llm = getLLM() else {
                throw NSError(domain: "ActionCoordinator", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No LLM loaded."])
            }
            onStateChange?(.generating)
            defer { onStateChange?(.idle) }

            // Determine which calendar tool to use based on the query.
            let date = q.date ?? {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                // Default to today if no date extracted
                return fmt.string(from: Date())
            }()
            let nextDay = {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                let d = fmt.date(from: date) ?? Date()
                return fmt.string(from: Calendar.current.date(byAdding: .day, value: 1, to: d)!)
            }()

            // Run both list_events and find_free_time for a comprehensive answer.
            let listTool = ListEventsTool()
            let freeTool = FindFreeTimeTool()

            let events = try await listTool.execute(arguments: ["start_date": date, "end_date": nextDay])
            let freeTime = try await freeTool.execute(arguments: ["date": date])

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime]
            let nowISO = isoFmt.string(from: Date())

            let calContext = "Events:\n\(events)\n\nFree time:\n\(freeTime)"
            let summarizePrompt = """
            Current date/time: \(nowISO). The calendar data below is for \(date).
            The user asked: "\(q.query)"

            Calendar data:
            \(calContext)

            Answer their question naturally and concisely. Mention specific times.
            """
            let answer = try await llm.generate(prompt: summarizePrompt, maxTokens: 300)
            onDisplayResult?(answer.trimmingCharacters(in: .whitespacesAndNewlines))

        case .launchApp(let l):
            for name in l.appNames {
                // Try the exact name and common variations (e.g. "Apple Maps" → "Maps")
                let variations = [name] + name.split(separator: " ").map(String.init)
                var opened = false
                for variant in variations where !opened {
                    let candidates = [
                        "/Applications/\(variant).app",
                        "/Applications/Utilities/\(variant).app",
                        "/System/Applications/\(variant).app",
                        "/System/Applications/Utilities/\(variant).app",
                    ]
                    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        opened = true
                    }
                }
            }

        case .unknown:
            break  // confirm() returns false for .unknown; should not reach here
        }
    }
}
