import AppKit
import Carbon.HIToolbox

@MainActor
final class TextCaptureService {
    struct ClipboardSnapshot {
        /// Array of pasteboard items, each with their typed payloads.
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    }

    private var targetApp: NSRunningApplication?

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

    func pasteText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Paste into the currently focused app — not the one stored at recording start.
        // If the user switched apps during recording, respect their current focus.
        let currentApp = NSWorkspace.shared.frontmostApplication
        let pasteTarget = currentApp?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? targetApp  // Our app is focused (e.g., overlay) — fall back to stored target
            : currentApp
        pasteTarget?.activate()
        try await Task.sleep(for: .milliseconds(100))

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
