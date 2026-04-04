import Foundation

/// The parsed, structured intent produced by ActionRouter.
/// Passed between ActionRouter → ActionConfirmationPanel → EventKitService.
enum PendingAction: Sendable {

    struct CalendarEvent: Sendable {
        let title: String
        let startDate: Date
        let endDate: Date       // defaults to startDate + 1h if LLM omits
        let location: String?
        let calendarName: String?  // nil → system default calendar
    }

    struct Reminder: Sendable {
        let title: String
        let dueDate: Date?      // nil → reminder with no alarm
        let listName: String?   // nil → system default list
        let notes: String?
    }

    case calendarEvent(CalendarEvent)
    case reminder(Reminder)
    case unknown(transcript: String)  // LLM could not classify
}


// MARK: - UI Helpers

extension PendingAction {

    /// Human-readable summary shown in the NSAlert informative text.
    var confirmationSummary: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        switch self {
        case .calendarEvent(let e):
            var s = "\"\(e.title)\"\n\(fmt.string(from: e.startDate)) – \(fmt.string(from: e.endDate))"
            if let loc = e.location { s += "\n\(loc)" }
            return s
        case .reminder(let r):
            var s = "\"\(r.title)\""
            if let due = r.dueDate { s += "\nDue: \(fmt.string(from: due))" }
            if let notes = r.notes, !notes.isEmpty { s += "\n\(notes)" }
            return s
        case .unknown(let t):
            return "Could not understand: \"\(t)\""
        }
    }

    /// Label for the primary (confirm) button.
    var actionVerb: String {
        switch self {
        case .calendarEvent: return "Add to Calendar"
        case .reminder:      return "Add Reminder"
        case .unknown:       return "OK"
        }
    }
}
