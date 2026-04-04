import Foundation

/// Parses a voice transcript into a structured PendingAction using the LLM.
/// Stateless — no stored properties. Returns `.unknown` on any parse failure, never throws
/// for parsing errors (only for the underlying LLM call).
struct ActionRouter {

    static let maxTokens = 250

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
        Current date and time (ISO 8601): \(nowISO)  (\(weekday))

        The user dictated a voice command. Classify it as ONE of:
        1. calendar_event — something scheduled at a specific time/date
        2. reminder — a to-do or reminder (may or may not have a due date)
        3. unknown — cannot be classified as either

        Respond with ONLY a JSON object on a single line. No markdown, no commentary.

        For calendar_event:
        {"type":"calendar_event","title":"...","start_iso":"<ISO8601>","end_iso":"<ISO8601>","location":"..." or null}

        For reminder:
        {"type":"reminder","title":"...","due_iso":"<ISO8601>" or null,"notes":"..." or null}

        For unknown:
        {"type":"unknown"}

        Rules:
        - "remind me to…" or "don't forget to…" → reminder. "schedule", "book", "meet" → calendar_event.
        - Resolve relative dates using the current date above ("tomorrow", "next Monday", "in 2 hours").
        - Default event duration: 1 hour if end time not specified.
        - Title must be clean and concise (no filler words like "please", "can you").
        - ISO 8601 format: YYYY-MM-DDTHH:mm:ss (local time, no timezone suffix needed).
        - If you cannot determine a start time for a calendar event, make it a reminder instead.
        - If the intent is unclear, output {"type":"unknown"}.

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
        let end: Date
        if let endStr = dict["end_iso"] as? String, let parsedEnd = parseDate(endStr) {
            end = parsedEnd
        } else {
            end = start.addingTimeInterval(3600)
        }
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
