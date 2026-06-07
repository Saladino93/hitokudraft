import ApplicationServices

/// Accessibility-API-based implementation of `EditabilityDetector`.
///
/// "Editable" here means **there is a real text insertion point (caret)** at the
/// focused element — the deterministic "is there a cursor?" test. With a caret,
/// Voice Edit pastes the result; without one (a read-only web page in Safari, the
/// desktop, a Finder window) it shows the result in the overlay.
///
/// Detection strategy (fail-open):
/// 1. Caret signals — `kAXSelectedTextRangeAttribute` (primary), plus
///    `kAXSelectedTextAttribute` / `kAXInsertionPointLineNumberAttribute` for native
///    text views. These appear in TextEdit, Notes, text fields, and web editors
///    (Mail/Gmail) that hold a caret — but ALSO, spuriously, on non-text containers
///    such as the Finder desktop's focused `AXGroup`. So a caret only counts when the
///    element is corroborated as a real text element (see `caretRoles` / string value).
/// 2. Standard editable text roles as a backstop (a focused, empty text field has a
///    caret even if the range is briefly unavailable).
/// 3. If the focused element can't be read at all (permission revoked), return `true`
///    so the app falls back to its prior paste behavior.
struct AXEditabilityDetector: EditabilityDetector {

    /// Roles whose caret signal is a genuine text insertion point. `AXWebArea` and
    /// `AXTextView` are included so web editors and AppKit text views paste correctly.
    private static let caretRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXWebArea",
        "AXTextView",
    ]

    /// Roles treated as editable by role alone (focused field always has a caret).
    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    func focusedElementIsEditable() -> Bool {
        let trusted = AXIsProcessTrusted()
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else {
            // No focused element. If accessibility is granted, there is genuinely
            // nothing focused (e.g. the desktop or a Finder window with no text
            // field), so there is no caret to paste into: show in the overlay.
            // Only fall back to paste when AX is not granted and we truly can't tell.
            return !trusted
        }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"

        // Gather caret signals. Any of these *can* indicate a text cursor — but a
        // generic container (the Finder desktop's AXGroup) can report a spurious
        // selectedTextRange that is a selection, not a text caret.
        let hasCaretSignal = Self.hasAttribute(focused, kAXSelectedTextRangeAttribute)
            || Self.hasAttribute(focused, kAXSelectedTextAttribute)
            || Self.hasAttribute(focused, kAXInsertionPointLineNumberAttribute)

        // A caret only counts on a real text element: an allowlisted text role, or an
        // element that actually exposes text content (a String AX value). This rejects
        // the desktop AXGroup (no string value) while keeping web editors working.
        if hasCaretSignal, Self.caretRoles.contains(role) || Self.hasStringValue(focused) {
            return true
        }

        // Backstop: standard editable text roles (focused text field always has a caret).
        if Self.editableRoles.contains(role) {
            return true
        }

        return false
    }

    /// True when the attribute is present and non-nil on the element.
    private static func hasAttribute(_ element: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success && ref != nil
    }

    /// True when the element exposes a String `kAXValueAttribute` — a strong signal it
    /// holds editable text content, used to corroborate a caret on non-standard roles.
    private static func hasStringValue(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return false
        }
        return (ref as? String) != nil
    }
}
