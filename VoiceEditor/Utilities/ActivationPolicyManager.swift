import AppKit

/// Brings a utility window to the front without toggling the Dock icon.
/// LSUIElement apps on macOS 14+ can activate without setActivationPolicy(.regular).
final class ActivationPolicyManager {
    static let shared = ActivationPolicyManager()
    private init() {}

    func trackWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Forces all titled app windows to the front. Call after openSettings() / About.
    func bringWindowsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.styleMask.contains(.titled) && $0.isVisible }
                .forEach {
                    $0.orderFrontRegardless()
                    $0.makeKeyAndOrderFront(nil)
                }
        }
    }
}
