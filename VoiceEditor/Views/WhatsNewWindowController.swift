import AppKit
import SwiftUI

// MARK: - Controller

final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WhatsNewWindowController()

    private init() {
        let view = WhatsNewView()
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = .minSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Runs once when the window closes; lets launch-time windows queue up behind it.
    private var onDismiss: (@MainActor () -> Void)?

    func show() {
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let next = onDismiss
        onDismiss = nil
        next?()
    }

    /// Call once at launch. Shows the window if the user just upgraded, then
    /// records the current version so it won't appear again until the next update.
    /// `then` runs after the window is dismissed, or after the same launch delay
    /// when there is nothing new to show.
    static func checkAndShowIfNeeded(then next: @escaping @MainActor () -> Void = {}) {
        let defaults = UserDefaults.standard
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastSeen = defaults.string(forKey: "whatsNewLastSeenVersion") ?? ""

        // Always record current version so the window won't reappear.
        defaults.set(current, forKey: "whatsNewLastSeenVersion")

        // Show on upgrade (lastSeen differs) and on first run/fresh install.
        // Suppressed only when relaunching the same version.
        let shouldShow = current != lastSeen

        // Delay slightly so the menu bar is fully set up before any window appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard shouldShow else { next(); return }
            WhatsNewWindowController.shared.onDismiss = next
            WhatsNewWindowController.shared.show()
        }
    }
}

// MARK: - View

private struct WhatsNewBullet {
    let symbol: String
    let title: String
    let detail: String
}

private let whatsNewBullets: [WhatsNewBullet] = [
    WhatsNewBullet(
        symbol: "checkmark.seal",
        title: "Launches reliably on macOS 27",
        detail: "Fixed a crash at launch on macOS 27. If something fails to load at startup, Hitoku Draft now recovers on its own."
    ),
    WhatsNewBullet(
        symbol: "clock.arrow.circlepath",
        title: "Your history in Settings",
        detail: "A new History tab lets you search, copy, export, or delete past dictations and answers. Turn saving off anytime. Everything stays on your Mac."
    ),
    WhatsNewBullet(
        symbol: "cpu",
        title: "Pick an AI model on first launch",
        detail: "If you have not chosen an AI model yet, Hitoku Draft offers to install the one recommended for your Mac, or you can keep using transcription only."
    ),
    WhatsNewBullet(
        symbol: "speaker.wave.2",
        title: "Better read-aloud",
        detail: "Stop now stops right away, and the progress bar follows the voice smoothly."
    ),
    WhatsNewBullet(
        symbol: "lock.shield",
        title: "Safer pasting and more privacy",
        detail: "Results only go into the app you started from, never into password fields (they appear in the overlay instead). Web access only opens links you mention or select, and your history is private to your account."
    ),
    WhatsNewBullet(
        symbol: "stop.circle",
        title: "Instant cancel",
        detail: "Cancelling a response now stops the AI model immediately."
    ),
]

private struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New")
                    .font(.system(size: 22, weight: .bold))
                Text("Hitoku Draft \(versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Bullets
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(whatsNewBullets.enumerated()), id: \.offset) { _, bullet in
                        BulletRow(bullet: bullet)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Continue") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(WindowActivatorBridge())
    }
}

private struct BulletRow: View {
    let bullet: WhatsNewBullet

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: bullet.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(bullet.title)
                    .font(.headline)
                Text(bullet.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Window Activation

/// Bridges into AppKit to force-activate this window for LSUIElement apps.
private struct WindowActivatorBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class ActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                ActivationPolicyManager.shared.trackWindow(window)
                window.standardWindowButton(.closeButton)?.keyEquivalent = "\u{1B}"
                window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = []
            }
        }
    }
}
