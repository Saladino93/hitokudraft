import ApplicationServices

/// Accessibility-API-based implementation of `EditabilityDetector`.
///
/// Detection strategy (two-pass, fail-open):
/// 1. Read `kAXRoleAttribute` from the system-wide focused element and check
///    against a whitelist of standard editable roles.
/// 2. If role is absent or not in the whitelist, probe
///    `kAXInsertionPointLineNumberAttribute` — macOS only returns `.success`
///    for this attribute on elements that actually accept a text cursor
///    (covers contenteditable web areas that have non-standard role strings).
/// 3. If any AX call fails (permission revoked, element gone), return `true`
///    so the app falls back to the existing paste behavior.
///
/// Uses the same `AXUIElementCopyAttributeValue` + `unsafeBitCast` pattern
/// as `ContextCaptureService` — consistent and tested in production.
struct AXEditabilityDetector: EditabilityDetector {

    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
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
            return true
        }

        // Step 3: Insertion-point probe — present only in elements that accept a cursor.
        var ipRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            focused, kAXInsertionPointLineNumberAttribute as CFString, &ipRef
        ) == .success
    }
}
