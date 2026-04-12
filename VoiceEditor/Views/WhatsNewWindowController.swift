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
        symbol: "waveform.circle",
        title: "Redesigned Overlay",
        detail: "Four visual states — Listening, Generating, Speaking, and Done — with animated waveform bars, pulsing dots, sentence-level TTS highlighting, and action buttons. Six themes available."
    ),
    WhatsNewBullet(
        symbol: "cpu",
        title: "Gemma 4 Multimodal",
        detail: "Native audio + vision inference via LiteRT. Speak directly to the model without a separate speech-to-text step. Gemma 4 E2B (2.6 GB) and E4B (3.7 GB)."
    ),
    WhatsNewBullet(
        symbol: "speaker.wave.2",
        title: "Voice Readback & TTS",
        detail: "Results are read aloud in non-editable contexts. Two TTS engines: Kokoro (multi-voice, speed control) and PocketTTS. Streaming synthesis with sentence highlighting."
    ),
    WhatsNewBullet(
        symbol: "globe",
        title: "Web Search & Browser Context",
        detail: "The AI can search DuckDuckGo, read web pages, and extract full-page text from Safari, Chrome, Arc, Brave, and Edge."
    ),
    WhatsNewBullet(
        symbol: "calendar",
        title: "Calendar Tools",
        detail: "Ask about your schedule via voice: \"Am I free tomorrow?\", \"What's on my calendar today?\". Works with both Ctrl+A and Ctrl+Z."
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
