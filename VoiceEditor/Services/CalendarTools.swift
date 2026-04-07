import EventKit
import Foundation

// MARK: - List Events Tool

/// Lists calendar events in a date range.
struct ListEventsTool: Tool {
    let name = "list_events"
    let toolDescription = "List calendar events for a date range. Use when the user asks what's on their calendar."
    let parameterDescription = "{\"start_date\": \"YYYY-MM-DD\", \"end_date\": \"YYYY-MM-DD\"}"

    func execute(arguments: [String: String]) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            return "Calendar access denied."
        }

        let start = parseDate(arguments["start_date"]) ?? Calendar.current.startOfDay(for: Date())
        let end = parseDate(arguments["end_date"])
            ?? Calendar.current.date(byAdding: .day, value: 1, to: start)!

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            return "No events found for \(formatDate(start)) – \(formatDate(end))."
        }

        return events.prefix(10).map { event in
            let time = formatTime(event.startDate) + " – " + formatTime(event.endDate)
            var line = "• \(time): \(event.title ?? "Untitled")"
            if let loc = event.location, !loc.isEmpty { line += " (\(loc))" }
            if let cal = event.calendar { line += " [\(cal.title)]" }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - Find Free Time Tool

/// Finds free time slots between events on a given date.
struct FindFreeTimeTool: Tool {
    let name = "find_free_time"
    let toolDescription = "Find free time slots on a given date. Use when the user asks when they're available."
    let parameterDescription = "{\"date\": \"YYYY-MM-DD\", \"start_hour\": \"9\", \"end_hour\": \"18\"}"

    func execute(arguments: [String: String]) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            return "Calendar access denied."
        }

        let cal = Calendar.current
        let baseDate = parseDate(arguments["date"]) ?? cal.startOfDay(for: Date())
        let startHour = Int(arguments["start_hour"] ?? "9") ?? 9
        let endHour = Int(arguments["end_hour"] ?? "18") ?? 18

        let dayStart = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: baseDate)!
        let dayEnd = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: baseDate)!

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Find gaps between events
        var freeSlots: [(Date, Date)] = []
        var cursor = dayStart

        for event in events {
            if event.startDate > cursor {
                freeSlots.append((cursor, event.startDate))
            }
            if event.endDate > cursor {
                cursor = event.endDate
            }
        }
        if cursor < dayEnd {
            freeSlots.append((cursor, dayEnd))
        }

        // Filter out tiny gaps (< 15 min)
        let meaningful = freeSlots.filter {
            $0.1.timeIntervalSince($0.0) >= 15 * 60
        }

        guard !meaningful.isEmpty else {
            return "No free time found on \(formatDate(baseDate)) between \(startHour):00 and \(endHour):00."
        }

        return "Free time on \(formatDate(baseDate)):\n" + meaningful.map { slot in
            let duration = Int(slot.1.timeIntervalSince(slot.0) / 60)
            return "• \(formatTime(slot.0)) – \(formatTime(slot.1)) (\(duration) min)"
        }.joined(separator: "\n")
    }
}

// MARK: - Check Availability Tool

/// Checks if a specific time slot is free.
struct CheckAvailabilityTool: Tool {
    let name = "check_availability"
    let toolDescription = "Check if a specific date/time is free on the calendar."
    let parameterDescription = "{\"datetime\": \"YYYY-MM-DDTHH:mm\", \"duration_minutes\": \"60\"}"

    func execute(arguments: [String: String]) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            return "Calendar access denied."
        }

        guard let dt = arguments["datetime"],
              let start = parseDateTime(dt) else {
            return "Error: provide 'datetime' in YYYY-MM-DDTHH:mm format."
        }

        let minutes = Int(arguments["duration_minutes"] ?? "60") ?? 60
        let end = start.addingTimeInterval(Double(minutes) * 60)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let conflicts = store.events(matching: predicate).filter { !$0.isAllDay }

        if conflicts.isEmpty {
            return "✓ You're free from \(formatTime(start)) to \(formatTime(end)) on \(formatDate(start))."
        } else {
            let list = conflicts.map { "• \(formatTime($0.startDate))–\(formatTime($0.endDate)): \($0.title ?? "Untitled")" }
                .joined(separator: "\n")
            return "✗ Conflicts found:\n\(list)"
        }
    }
}

// MARK: - Helpers

private func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.date(from: s)
}

private func parseDateTime(_ s: String) -> Date? {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
        fmt.dateFormat = format
        if let d = fmt.date(from: s) { return d }
    }
    return nil
}

private func formatDate(_ d: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .none
    return fmt.string(from: d)
}

private func formatTime(_ d: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .none
    fmt.timeStyle = .short
    return fmt.string(from: d)
}
