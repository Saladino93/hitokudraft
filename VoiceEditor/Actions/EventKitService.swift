import EventKit
import Foundation

/// Thin wrapper around EKEventStore — Calendar and Reminders creation only.
/// No read operations, no listing — purely write-once for v1 Action Mode.
@MainActor
final class EventKitService {

    private let store = EKEventStore()

    // MARK: - Permission

    enum EKPermission { case granted, denied, notDetermined }

    func requestCalendarAccess() async -> EKPermission {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                // requestFullAccessToEvents is required (not write-only) because
                // createCalendarEvent reads store.defaultCalendarForNewEvents,
                // which is a read operation that returns nil under write-only access.
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    func requestRemindersAccess() async -> EKPermission {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: .reminder)
            }
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    // MARK: - Create

    func createCalendarEvent(_ action: PendingAction.CalendarEvent) async throws {
        let event = EKEvent(eventStore: store)
        event.title = action.title
        event.startDate = action.startDate
        event.endDate = action.endDate
        event.location = action.location
        if let name = action.calendarName,
           let cal = store.calendars(for: .event).first(where: { $0.title == name }) {
            event.calendar = cal
        } else {
            guard let cal = store.defaultCalendarForNewEvents else {
                throw EventKitError.saveFailed("No default calendar found. Check Calendar app settings.")
            }
            event.calendar = cal
        }
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw EventKitError.saveFailed(error.localizedDescription)
        }
    }

    func createReminder(_ action: PendingAction.Reminder) async throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = action.title
        reminder.notes = action.notes
        if let due = action.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            let alarm = EKAlarm(absoluteDate: due)
            reminder.addAlarm(alarm)
        }
        if let name = action.listName,
           let list = store.calendars(for: .reminder).first(where: { $0.title == name }) {
            reminder.calendar = list
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Conflict Detection

    /// Returns a list of event titles that overlap with the given time range.
    func findConflicts(start: Date, end: Date) -> [String] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events.map { $0.title ?? "Untitled" }
    }

    // MARK: - Errors

    enum EventKitError: LocalizedError {
        case accessDenied(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let msg): return "Permission denied: \(msg)"
            case .saveFailed(let msg):   return "Could not save: \(msg)"
            }
        }
    }
}
