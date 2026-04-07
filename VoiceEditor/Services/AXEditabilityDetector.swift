import ApplicationServices

/// Accessibility-API-based implementation of `EditabilityDetector`.
///
/// Detection strategy (fail-open):
/// 1. Read `kAXRoleAttribute` from the system-wide focused element and check
///    against a whitelist of standard editable roles.
/// 2. Check `kAXSelectedTextAttribute` — present on any element that holds a
///    text cursor, including native text views that report a non-standard role.
/// 3. Probe `kAXInsertionPointLineNumberAttribute` — native text views (Terminal).
/// 4. Check `kAXSelectedTextRangeAttribute` settability — covers remaining cases.
/// 5. If any AX call fails (permission revoked, element gone), return `true`
///    so the app falls back to the existing paste behavior.
struct AXEditabilityDetector: EditabilityDetector {

    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        // WebKit-based editors (Apple Mail compose, contenteditable pages in browsers,
        // Notion, etc.) report role AXWebArea. The compose body receives keyboard focus
        // and expects Cmd+V paste; treating it as non-editable wrongly shows the overlay.
        "AXWebArea",
    ]

    func focusedElementIsEditable() -> Bool {
        // Step 1: Obtain the system-wide focused element.
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else {
            return true  // AX unavailable — fail open
        }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)

        // Step 2: Role whitelist check.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXRoleAttribute as CFString, &roleRef
        ) == .success,
           let role = roleRef as? String,
           Self.editableRoles.contains(role) {
            if role == "AXWebArea" {
                // AXWebArea matches both read-only articles and web editors (Gmail, Notion).
                // Refine: only treat as editable if the text range is settable — true for
                // contentEditable/input elements, false for static article pages.
                var webSettable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(
                    focused, kAXSelectedTextRangeAttribute as CFString, &webSettable
                ) == .success && webSettable.boolValue {
                    return true  // Actual web editor
                }
                // Fall through to other checks for read-only web content
            } else {
                return true
            }
        }

        // Step 3: Selected-text attribute — present on any element that holds a text cursor,
        //         including native text views with non-standard roles.
        //         Returns .success with an empty string when no text is selected but a cursor exists.
        var selRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, &selRef
        ) == .success {
            return true
        }

        // Step 4: Insertion-point probe — fallback for native text views that expose
        //         kAXInsertionPointLineNumberAttribute (e.g. Terminal input lines).
        var ipRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXInsertionPointLineNumberAttribute as CFString, &ipRef
        ) == .success {
            return true
        }

        // Step 5: Check if kAXSelectedTextRangeAttribute is settable — editable text
        //         allows cursor repositioning; non-editable elements do not.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextRangeAttribute as CFString, &settable
        ) == .success && settable.boolValue {
            return true
        }

        return false
    }
}
