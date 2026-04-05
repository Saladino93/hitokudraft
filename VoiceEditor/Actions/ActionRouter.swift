import Foundation

/// Parses a voice transcript into a structured PendingAction using the LLM.
/// Stateless — no stored properties. Returns `.unknown` on any parse failure, never throws
/// for parsing errors (only for the underlying LLM call).
struct ActionRouter {

    static let maxTokens = 500  // bumped from 250 — email body may be several sentences

    // MARK: - Entry Point

    static func route(
        transcript: String,
        llm: any LLMService
    ) async throws -> PendingAction {
        let now = Date()
        let prompt = buildPrompt(transcript: transcript, now: now)
        let raw = try await llm.generate(prompt: prompt, maxTokens: maxTokens)
        return parse(raw: raw, relativeTo: now)
    }

    // MARK: - Prompt Construction

    static func buildPrompt(transcript: String, now: Date) -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let nowISO = isoFmt.string(from: now)
        let weekday = Calendar.current.weekdaySymbols[
            Calendar.current.component(.weekday, from: now) - 1
        ]

        return """
        Current date and time: \(nowISO)  (\(weekday))

        Classify the user's voice command as ONE of:
        1. calendar_event — scheduled at a specific time/date
        2. reminder — a to-do or reminder (may or may not have a due date)
        3. note — create a note in Apple Notes
        4. timer — set a countdown timer (not a calendar event)
        5. email — compose an email (opens compose window for review; never auto-sends)
        6. unknown — cannot be classified

        Respond with ONLY a JSON object on a single line. No markdown, no commentary.

        For calendar_event:
        {"type":"calendar_event","title":"...","start_iso":"<YYYY-MM-DDTHH:mm:ss>","duration_minutes":<number>,"location":"..." or null}

        For reminder:
        {"type":"reminder","title":"...","due_iso":"<YYYY-MM-DDTHH:mm:ss>" or null,"notes":"..." or null}

        For note:
        {"type":"note","title":"...","body":"..."}

        For timer:
        {"type":"timer","duration_seconds":<number>,"label":"..."}

        For email:
        {"type":"email","subject":"...","body":"..."}


        For unknown:
        {"type":"unknown"}

        Rules:
        - "remind me to", "don't forget" → reminder. "schedule", "book", "meeting", "appointment" → calendar_event.
        - "take a note", "note that", "jot down" → note. Body is the content; title is a short summary.
        - "set a timer", "timer for", "remind me in X minutes/seconds" (countdown) → timer.
        - "email", "send a message to", "write to" → email. Subject MUST be non-empty (derive from body if not stated, max 50 chars). Body is a complete, naturally-written email — write full sentences on the user's behalf, expanding their intent. Do NOT just copy the user's words verbatim; write as if composing the email for them.
        - Resolve relative dates ("tomorrow", "next Monday", "in 2 hours") using the current date above.
        - duration_minutes: use ONLY what the user explicitly stated (e.g. "2-hour meeting" → 120). Otherwise output 60.
        - duration_seconds: convert as needed (e.g. "10 minutes" → 600, "30 seconds" → 30).
        - Title/subject must be clean and concise (no filler words).
        - Dates are local time, no timezone suffix.
        - If you cannot determine a start time for a calendar event, make it a reminder instead.
        - If intent is unclear, output {"type":"unknown"}.

        User command: \(transcript)

        JSON:
        """
    }

    // MARK: - JSON Parsing

    static func parse(raw: String, relativeTo now: Date) -> PendingAction {
        // Strip any accidental markdown fences or surrounding whitespace
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String
        else {
            return .unknown(transcript: raw)
        }

        switch type {
        case "calendar_event":
            return parseCalendarEvent(dict: dict, raw: raw)
        case "reminder":
            return parseReminder(dict: dict, raw: raw)
        case "note":
            return parseNote(dict: dict, raw: raw)
        case "timer":
            return parseTimer(dict: dict, raw: raw)
        case "email":
            return parseEmail(dict: dict, raw: raw)
        default:
            return .unknown(transcript: raw)
        }
    }

    // MARK: - Private Helpers

    private static func parseCalendarEvent(dict: [String: Any], raw: String) -> PendingAction {
        guard let title = dict["title"] as? String, !title.isEmpty,
              let startStr = dict["start_iso"] as? String,
              let start = parseDate(startStr)
        else {
            return .unknown(transcript: raw)
        }
        // Use duration_minutes; clamp to 15min–8h; default 60 min
        let rawMinutes = dict["duration_minutes"] as? Int ?? 60
        let clampedMinutes = max(15, min(rawMinutes, 480))
        let end = start.addingTimeInterval(Double(clampedMinutes) * 60)
        let location = dict["location"] as? String
        return .calendarEvent(.init(
            title: title,
            startDate: start,
            endDate: end,
            location: location,
            calendarName: nil
        ))
    }

    private static func parseReminder(dict: [String: Any], raw: String) -> PendingAction {
        guard let title = dict["title"] as? String, !title.isEmpty else {
            return .unknown(transcript: raw)
        }
        let due = (dict["due_iso"] as? String).flatMap { parseDate($0) }
        let notes = dict["notes"] as? String
        return .reminder(.init(title: title, dueDate: due, listName: nil, notes: notes))
    }

    private static func parseNote(dict: [String: Any], raw: String) -> PendingAction {
        guard let title = dict["title"] as? String, !title.isEmpty,
              let body = dict["body"] as? String
        else {
            return .unknown(transcript: raw)
        }
        return .note(.init(title: title, body: body))
    }

    private static func parseTimer(dict: [String: Any], raw: String) -> PendingAction {
        guard let seconds = dict["duration_seconds"] as? Int, seconds > 0 else {
            return .unknown(transcript: raw)
        }
        let label = dict["label"] as? String ?? "Timer"
        return .timer(.init(durationSeconds: seconds, label: label))
    }

    private static func parseEmail(dict: [String: Any], raw: String) -> PendingAction {
        guard let body = dict["body"] as? String else {
            return .unknown(transcript: raw)
        }
        var subject = (dict["subject"] as? String) ?? ""
        // Fallback: derive subject from first few words of body
        if subject.trimmingCharacters(in: .whitespaces).isEmpty {
            let words = body.split(separator: " ").prefix(8).joined(separator: " ")
            subject = String(words.prefix(50))
        }
        // Cap at 50 chars
        if subject.count > 50 {
            subject = String(subject.prefix(47)) + "..."
        }
        return .email(.init(subject: subject, body: body))
    }

    /// Parses an ISO-8601-style date string as **local time**.
    /// The LLM outputs local times without a timezone suffix (per our prompt),
    /// so we must NOT use ISO8601DateFormatter (it assumes UTC for tz-less strings).
    private static func parseDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        // timeZone intentionally left at default (current locale) — correct for LLM output
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            fmt.dateFormat = format
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }
}
