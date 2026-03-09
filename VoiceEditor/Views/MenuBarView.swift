import SwiftUI

struct MenuBarMenu: View {
    @ObservedObject var coordinator: ConversationCoordinator

    var body: some View {
        Text(statusText)

        Divider()

        SettingsLink {
            Text("Preferences...")
        }
        .keyboardShortcut(",")

        Divider()

        Button("About Hitoku Draft") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationURL: URL(string: "https://hitoku.me")!
            ])
        }

        Button("Acknowledgments\u{2026}") {
            AcknowledgmentsWindowController.shared.show()
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
