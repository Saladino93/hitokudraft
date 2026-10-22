import AppKit
import Carbon.HIToolbox

@MainActor
final class TextCaptureService {
    struct ClipboardSnapshot {
        /// Array of pasteboard items, each with their typed payloads.
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    }

    /// Why `pasteText` declined to paste. The caller shows the text in the overlay instead.
    enum TextCaptureError: Error {
        /// The frontmost app is no longer the one the text was captured from.
        case targetAppChanged
        /// Secure keyboard entry is on (a password field is focused somewhere).
        case secureInputActive
    }

    private var targetApp: NSRunningApplication?

    /// True while any process has secure keyboard entry enabled (password fields,
    /// Terminal's "Secure Keyboard Entry").
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    func rememberTargetApp() {
        targetApp = NSWorkspace.shared.frontmostApplication
    }

    func saveClipboard() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        var snapshotItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry.append((type, data))
                }
            }
            if !entry.isEmpty { snapshotItems.append(entry) }
        }
        return ClipboardSnapshot(items: snapshotItems)
    }

    func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var objects: [NSPasteboardItem] = []
        for entry in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            objects.append(item)
        }
        pasteboard.writeObjects(objects)
    }

    func captureSelectedText() async throws -> String {
        rememberTargetApp()
        let pasteboard = NSPasteboard.general

        let previousChangeCount = pasteboard.changeCount

        try await Task.sleep(for: .milliseconds(50))   // let run loop settle
        simulateKeyPress(keyCode: 0x08, flags: .maskCommand)  // Cmd+C
        try await Task.sleep(for: .milliseconds(300))

        guard pasteboard.changeCount != previousChangeCount else {
            return ""  // No selection captured
        }

        // If the clipboard has file references (e.g. Finder file selection), treat as no text selected.
        // File copies always include public.file-url; text selections never do.
        if pasteboard.types?.contains(.fileURL) == true {
            return ""
        }

        return pasteboard.string(forType: .string) ?? ""
    }

    /// Pastes `text` into the app the text was captured from.
    ///
    /// Throws `TextCaptureError` (without touching the pasteboard) when the frontmost
    /// app is no longer the recorded target, or when secure input is active, so the
    /// caller can show the result in the overlay instead of typing it somewhere else.
    func pasteText(_ text: String) async throws {
        let currentApp = NSWorkspace.shared.frontmostApplication
        let pasteTarget: NSRunningApplication?
        if currentApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            pasteTarget = targetApp  // Our app is focused (e.g., overlay) — fall back to stored target
        } else {
            // The user switched apps while the result was generated: never paste into
            // an app the text didn't come from.
            if let targetApp, currentApp?.bundleIdentifier != targetApp.bundleIdentifier {
                throw TextCaptureError.targetAppChanged
            }
            pasteTarget = currentApp
        }
        pasteTarget?.activate()
        try await Task.sleep(for: .milliseconds(100))

        // Checked after activation so it reflects the target's focused field.
        guard !Self.isSecureInputActive() else {
            throw TextCaptureError.secureInputActive
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateKeyPress(keyCode: 0x09, flags: .maskCommand)  // Cmd+V
        try await Task.sleep(for: .milliseconds(250))
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        usleep(40_000)  // 40ms — let native apps process keyDown before keyUp

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
