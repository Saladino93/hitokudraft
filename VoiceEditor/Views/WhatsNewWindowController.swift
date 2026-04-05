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

    func show() {
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Call once at launch. Shows the window if the user just upgraded, then
    /// records the current version so it won't appear again until the next update.
    static func checkAndShowIfNeeded() {
        let defaults = UserDefaults.standard
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastSeen = defaults.string(forKey: "whatsNewLastSeenVersion") ?? ""

        // Always record current version so the window won't reappear.
        defaults.set(current, forKey: "whatsNewLastSeenVersion")

        // Show on upgrade (lastSeen differs) and on first run/fresh install.
        // Suppressed only when relaunching the same version.
        guard current != lastSeen else { return }

        // Delay slightly so the menu bar is fully set up before the window appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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
        symbol: "note.text.badge.plus",
        title: "Notes, Timer & Email Actions",
        detail: "Action Mode now supports three new commands: create Apple Notes, set countdown timers with macOS notifications, and compose emails in your default mail client."
    ),
    WhatsNewBullet(
        symbol: "curlybraces",
        title: "Code Syntax Highlighting",
        detail: "LLM responses containing code blocks are rendered with Atom One Dark syntax coloring — Python, Swift, JavaScript, Go, Rust, and 10 more languages."
    ),
    WhatsNewBullet(
        symbol: "function",
        title: "LaTeX Math Rendering",
        detail: "Inline and display math ($…$, $$…$$, \\[…\\]) is rendered natively using SwiftMath — no WebKit, no browser overhead."
    ),
    WhatsNewBullet(
        symbol: "rectangle.and.text.magnifyingglass",
        title: "Overlay Display Mode",
        detail: "When the focused element cannot accept text (PDF viewer, Finder, Terminal), the LLM result appears in the overlay for 20 seconds instead of pasting into the void."
    ),
    WhatsNewBullet(
        symbol: "waveform.badge.checkmark",
        title: "Polish Dictation",
        detail: "An optional post-processing pass removes filler words (um, uh, euh, äh…) and adds punctuation after each dictation recording stops."
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
