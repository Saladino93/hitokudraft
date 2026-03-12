import SwiftUI

struct MenuBarMenu: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusText)

        Divider()

        Button(L("menu.preferences")) {
            openSettings()
            ActivationPolicyManager.shared.bringWindowsToFront()
        }

        Button(L("menu.about")) {
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

        Button(L("menu.acknowledgments")) {
            AcknowledgmentsWindowController.shared.show()
            ActivationPolicyManager.shared.bringWindowsToFront()
        }

        Divider()

        Button(L("menu.quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:
            if coordinator.modelManager.llmReady {
                return L("status.ready")
            } else {
                return L("status.not_setup")
            }
        case .downloading:
            let msg = coordinator.modelManager.statusMessage
            return msg.isEmpty ? L("status.downloading") : msg
        case .warmingUp:
            return L("status.warming_up")
        case .listening:
            return L("status.listening")
        case .transcribing:
            return L("status.transcribing")
        case .generating:
            return L("status.generating")
        case .pasting:
            return L("status.pasting")
        case .dictating(let text):
            if text.isEmpty {
                return L("status.dictating")
            } else {
                let suffix = text.suffix(50)
                return L("status.dictating_prefix") + suffix
            }
        case .error(let message):
            return L("status.error_prefix") + message
        }
    }
}
