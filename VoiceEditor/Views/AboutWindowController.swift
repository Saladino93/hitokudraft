import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("menu.about")
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - About View

private struct AboutView: View {
    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }()

    private let copyright: String = {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© 2026 Hitoku. All rights reserved."
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // App icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Hitoku Draft")
                    .font(.system(size: 22, weight: .bold))

                Text(appVersion)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Link(copyright, destination: URL(string: "https://hitoku.me/draft/")!)
                    .font(.caption)

                Spacer().frame(height: 8)

                Button("Acknowledgments") {
                    AcknowledgmentsWindowController.shared.show()
                }
                .controlSize(.small)
            }

        }
        .padding(24)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(AboutWindowActivator())
    }
}

// MARK: - Window Activation

private struct AboutWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AboutActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class AboutActivatorView: NSView {
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
