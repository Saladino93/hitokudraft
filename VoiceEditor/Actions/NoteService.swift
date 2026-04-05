import Foundation

/// Creates notes in Apple Notes via AppleScript.
/// No special entitlement is needed beyond the existing
/// com.apple.security.automation.apple-events entitlement.
enum NoteService {

    enum NoteError: LocalizedError {
        case scriptFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "Could not create note: \(msg)"
            case .timeout: return "Notes did not respond in time — please grant automation permission if prompted, then try again."
            }
        }
    }

    /// Creates a new note in the default Notes account.
    /// Runs the AppleScript on a background thread to avoid blocking the main actor.
    static func createNote(title: String, body: String) async throws {
        let safeTitle = escapeAppleScript(title)
        let safeBody  = escapeAppleScript(body)

        let script = """
        tell application "Notes"
            make new note with properties {name:"\(safeTitle)", body:"\(safeBody)"} in default account
        end tell
        """

        // Race the AppleScript execution against a 30-second timeout.
        // On first use, macOS shows an automation permission dialog for Notes.
        // Without a timeout the app would appear frozen until the user responds.
        // Cancelling the group unblocks the caller; the AppleScript task may still
        // finish in the background (C code is not Swift-cancellation-aware).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                        throw NoteError.scriptFailed(msg)
                    }
                }.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw NoteError.timeout
            }
            try await group.next()!
            group.cancelAll()
        }
    }

    // MARK: - Private

    /// Escapes characters that would break an AppleScript double-quoted string literal.
    /// Newlines are replaced with AppleScript string concatenation (`" & return & "`)
    /// because AppleScript does not allow literal newlines inside string literals.
    private static func escapeAppleScript(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
    }
}
