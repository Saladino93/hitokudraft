import AppKit
import SwiftUI

/// Hosts the file-transcription UI in a small, Esc-dismissable window.
/// Follows the `AboutWindowController` singleton pattern.
@MainActor
final class TranscriptionWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TranscriptionWindowController()

    /// Held so the in-flight transcription can be cancelled when the window closes.
    private var model: FileTranscriptionModel?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 552, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Audio"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the window, starting from a clean state each time.
    func show(coordinator: ConversationCoordinator) {
        let model = FileTranscriptionModel(coordinator: coordinator)
        self.model = model
        window?.contentView = NSHostingView(rootView: FileTranscriptionView(model: model))
        window?.center()
        ActivationPolicyManager.shared.bringWindowsToFront()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
    }
}
