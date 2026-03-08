import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let voiceEdit = Self("voiceEdit", default: .init(.a, modifiers: [.control, .shift]))
    static let grammarFix = Self("grammarFix", default: .init(.z, modifiers: [.control, .shift]))
    static let dictation = Self("dictation", default: .init(.s, modifiers: [.control, .shift]))
}
