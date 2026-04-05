import Foundation

/// Creates notes in Apple Notes via AppleScript.
/// No special entitlement is needed beyond the existing
/// com.apple.security.automation.apple-events entitlement.
enum NoteService {

    enum NoteError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "Could not create note: \(msg)"
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

        try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(&error)
            if let error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                throw NoteError.scriptFailed(msg)
            }
        }.value
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
