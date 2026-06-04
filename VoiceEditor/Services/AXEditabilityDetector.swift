import ApplicationServices

/// Accessibility-API-based implementation of `EditabilityDetector`.
///
/// "Editable" here means **there is a real text insertion point (caret)** at the
/// focused element — the deterministic "is there a cursor?" test. With a caret,
/// Voice Edit pastes the result; without one (a read-only web page in Safari, an
/// editor that isn't focused in its text area) it shows the result in the overlay.
///
/// Detection strategy (fail-open):
/// 1. `kAXSelectedTextRangeAttribute` — the caret/selection range. This is the
///    primary signal: present in TextEdit, Notes, text fields, and web editors
///    (Mail/Gmail) that currently hold a caret; absent on a read-only page.
/// 2. `kAXSelectedTextAttribute` / `kAXInsertionPointLineNumberAttribute` — extra
///    caret signals for native text views (e.g. Terminal).
/// 3. Standard editable text roles as a backstop (a focused, empty text field has
///    a caret even if step 1 is briefly unavailable). `AXWebArea` is deliberately
///    NOT treated as editable by role — a focused web *page* is not a text cursor.
/// 4. If the focused element can't be read at all (permission revoked), return
///    `true` so the app falls back to its prior paste behavior.
struct AXEditabilityDetector: EditabilityDetector {

    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    func focusedElementIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else {
            return true  // AX unavailable — fail open (paste)
        }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)

        // Primary: is there a caret / selection range? (the "is there a cursor?" test)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, rangeRef != nil {
            return true
        }

        // Extra caret signals for native text views with non-standard roles.
        var selRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, &selRef
        ) == .success, selRef != nil {
            return true
        }
        var ipRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXInsertionPointLineNumberAttribute as CFString, &ipRef
        ) == .success, ipRef != nil {
            return true
        }

        // Backstop: standard editable text roles (focused text field always has a caret).
        // AXWebArea intentionally excluded — caught above only when it actually holds a caret.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXRoleAttribute as CFString, &roleRef
        ) == .success,
           let role = roleRef as? String,
           Self.editableRoles.contains(role) {
            return true
        }

        return false
    }
}
