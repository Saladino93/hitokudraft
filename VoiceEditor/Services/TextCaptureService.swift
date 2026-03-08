import AppKit
import Carbon.HIToolbox

@MainActor
final class TextCaptureService {
    struct ClipboardSnapshot {
        let items: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    func saveClipboard() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    items.append((type, data))
                }
            }
        }
        return ClipboardSnapshot(items: items)
    }

    func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in snapshot.items {
            item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
    }

    func captureSelectedText() async throws -> String {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount

        simulateKeyPress(keyCode: 0x08, flags: .maskCommand)  // Cmd+C
        try await Task.sleep(for: .milliseconds(150))

        guard pasteboard.changeCount != previousChangeCount else {
            return ""  // No selection captured
        }

        return pasteboard.string(forType: .string) ?? ""
    }

    func pasteText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateKeyPress(keyCode: 0x09, flags: .maskCommand)  // Cmd+V
        try await Task.sleep(for: .milliseconds(100))
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
