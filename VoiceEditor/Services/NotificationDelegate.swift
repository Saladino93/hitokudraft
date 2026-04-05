import UserNotifications

/// Ensures local notifications (e.g. from TimerService) are displayed as banners
/// even when the app is considered active by macOS.
///
/// Without this delegate, UNUserNotificationCenter silently drops notifications
/// delivered while the app is running — a common problem for LSUIElement menu bar apps.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationDelegate()

    private override init() {}

    /// Always present notifications as banners with sound, regardless of app state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
