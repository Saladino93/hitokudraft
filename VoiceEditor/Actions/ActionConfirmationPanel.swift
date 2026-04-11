import AppKit

/// Modal confirmation panel for Action Mode.
/// Uses NSAlert.runModal() — blocking and application-modal, ensuring the user
/// must acknowledge before anything is written to Calendar or Reminders.
///
/// Must be called on MainActor after `state = .idle` so the overlay has hidden.
@MainActor
struct ActionConfirmationPanel {

    /// Presents a modal alert and returns true if the user confirms.
    /// For `.unknown` actions, shows an informational alert and always returns false.
    /// `conflicts` is an optional list of existing event titles that overlap (calendar events only).
    static func confirm(_ action: PendingAction, conflicts: [String] = []) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch action {
        case .unknown:
            alert.messageText = "Action Not Recognized"
            alert.informativeText = action.confirmationSummary
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false

        case .calendarEvent:
            alert.messageText = conflicts.isEmpty ? "Add to Calendar?" : "⚠️ Calendar Conflict"
            var info = action.confirmationSummary
            if !conflicts.isEmpty {
                info += "\n\nConflicts with:\n" + conflicts.map { "• \($0)" }.joined(separator: "\n")
            }
            alert.informativeText = info
            alert.addButton(withTitle: conflicts.isEmpty ? action.actionVerb : "Add Anyway")
            alert.addButton(withTitle: "Cancel")

        case .reminder:
            alert.messageText = "Add Reminder?"
            alert.informativeText = action.confirmationSummary
            alert.addButton(withTitle: action.actionVerb)
            alert.addButton(withTitle: "Cancel")

        case .note:
            alert.messageText = "Create Note?"
            alert.informativeText = action.confirmationSummary
            alert.addButton(withTitle: action.actionVerb)
            alert.addButton(withTitle: "Cancel")

        case .timer:
            alert.messageText = "Set Timer?"
            alert.informativeText = action.confirmationSummary
            alert.addButton(withTitle: action.actionVerb)
            alert.addButton(withTitle: "Cancel")

        case .email:
            alert.messageText = "Compose Email?"
            alert.informativeText = action.confirmationSummary
            alert.addButton(withTitle: action.actionVerb)
            alert.addButton(withTitle: "Cancel")

        case .launchApp, .webSearch, .calendarQuery:
            // No confirmation needed — read-only and non-destructive.
            return true
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
}
