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
        await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestWriteOnlyAccessToEvents { granted, _ in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            } else {
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted ? .granted : .denied)
                }
            }
        }
    }

    func requestRemindersAccess() async -> EKPermission {
        await withCheckedContinuation { continuation in
            store.requestAccess(to: .reminder) { granted, _ in
                continuation.resume(returning: granted ? .granted : .denied)
            }
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
            event.calendar = store.defaultCalendarForNewEvents
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
