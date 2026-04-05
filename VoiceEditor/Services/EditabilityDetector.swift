import Foundation

/// Determines whether the currently focused UI element accepts text input.
///
/// Conformers must be `Sendable` so they can be called from async tasks
/// without requiring a MainActor hop — detection calls are fast and synchronous.
///
/// **Contract:** `focusedElementIsEditable()` must never throw and must
/// fail open (return `true`) on any detection error, so that existing paste
/// behavior is never silently broken by an AX failure.
protocol EditabilityDetector: Sendable {
    /// Returns `true` if the currently focused UI element can receive pasted text.
    func focusedElementIsEditable() -> Bool
}
