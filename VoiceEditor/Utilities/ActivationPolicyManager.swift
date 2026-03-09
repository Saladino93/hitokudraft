import AppKit

/// Brings a utility window to the front without toggling the Dock icon.
/// LSUIElement apps on macOS 14+ can activate without setActivationPolicy(.regular).
final class ActivationPolicyManager {
    static let shared = ActivationPolicyManager()
    private init() {}

    func trackWindow(_ window: NSWindow) {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}
