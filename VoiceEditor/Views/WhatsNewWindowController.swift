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
        symbol: "waveform",
        title: "Transcribe audio and video files",
        detail: "Open Transcribe File from the menu bar, drop in one or many recordings, and get clean text on your Mac. Switch between files and refine any transcript with your voice."
    ),
    WhatsNewBullet(
        symbol: "questionmark.circle",
        title: "How to use guide",
        detail: "A new Help tab in Settings walks through dictation, voice editing, tool use, file transcription, and privacy."
    ),
    WhatsNewBullet(
        symbol: "cpu",
        title: "More model choices",
        detail: "A larger Gemma 4 option for Macs with plenty of memory (text and audio), plus the ability to add more on-device community models from Settings."
    ),
    WhatsNewBullet(
        symbol: "textformat",
        title: "Formatted answers",
        detail: "Answers in the overlay now show formatting such as bold and italics."
    ),
    WhatsNewBullet(
        symbol: "globe",
        title: "Clearer web answers",
        detail: "Web answers list their sources, and no longer get stuck while generating."
    ),
    WhatsNewBullet(
        symbol: "checkmark.circle",
        title: "Reliable answers on screen",
        detail: "Asking a question with nothing selected now keeps the answer on screen. It stays while you read and closes shortly after."
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
