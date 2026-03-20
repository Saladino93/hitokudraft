import AppKit
import SwiftUI

@MainActor
final class LicenseWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: LicenseWindowController?

    static func show(licenseManager: LicenseManager) {
        if let existing = instance {
            existing.window?.orderFrontRegardless()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = LicenseWindowController(licenseManager: licenseManager)
        instance = controller
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(licenseManager: LicenseManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("license.activate_title")
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseActivationView(licenseManager: licenseManager)
            .background(LicenseWindowActivator()))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.instance = nil
    }
}

// MARK: - Window Activation

private struct LicenseWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class ActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                ActivationPolicyManager.shared.trackWindow(window)
            }
        }
    }
}
