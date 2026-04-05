import Foundation
import UserNotifications

/// Schedules a local macOS notification after a countdown.
/// No entitlement is required for local notifications on macOS.
enum TimerService {

    enum TimerError: LocalizedError {
        case denied
        case scheduleFailed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Notification permission denied. Enable notifications for Hitoku Draft in System Settings → Notifications."
            case .scheduleFailed(let msg):
                return "Could not set timer: \(msg)"
            }
        }
    }

    /// Requests notification permission (no-op if already granted) then schedules
    /// a local notification to fire after `durationSeconds`.
    static func setTimer(durationSeconds: Int, label: String) async throws {
        let center = UNUserNotificationCenter.current()

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            throw TimerError.scheduleFailed(error.localizedDescription)
        }
        guard granted else { throw TimerError.denied }

        let content = UNMutableNotificationContent()
        content.title = "Timer Done"
        content.body  = label.isEmpty ? "Your timer has ended." : label
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(1, durationSeconds)),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "timer-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            throw TimerError.scheduleFailed(error.localizedDescription)
        }
    }
}
