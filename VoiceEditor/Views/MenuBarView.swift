import SwiftUI

struct MenuBarMenu: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusText)

        Divider()

        Button("Preferences...") {
            openSettings()
            ActivationPolicyManager.shared.bringWindowsToFront()
        }
        .keyboardShortcut(",")

        Divider()

        Button("About Hitoku Draft") {
            let websiteURL = URL(string: "https://hitoku.me")!
            let credits = NSAttributedString(
                string: "hitoku.me",
                attributes: [
                    .link: websiteURL,
                    .foregroundColor: NSColor.linkColor
                ]
            )
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: credits
            ])
            ActivationPolicyManager.shared.bringWindowsToFront()
        }

        Button("Acknowledgments\u{2026}") {
            AcknowledgmentsWindowController.shared.show()
            ActivationPolicyManager.shared.bringWindowsToFront()
        }

        Divider()

        Button("Quit Hitoku Draft") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:
            if coordinator.modelManager.llmReady {
                return "Status: Ready"
            } else {
                return "Status: Not Set Up"
            }
        case .downloading:
            let msg = coordinator.modelManager.statusMessage
            return msg.isEmpty ? "Downloading..." : msg
        case .warmingUp:
            return "Warming up..."
        case .listening:
            return "Listening..."
        case .transcribing:
            return "Transcribing..."
        case .generating:
            return "Generating..."
        case .pasting:
            return "Pasting..."
        case .dictating(let text):
            if text.isEmpty {
                return "Dictating..."
            } else {
                let suffix = text.suffix(50)
                return "Dictating: ...\(suffix)"
            }
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
