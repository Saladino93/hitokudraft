import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let voiceEdit = Self("voiceEdit", default: .init(.z, modifiers: [.control]))
    static let grammarFix = Self("grammarFix", default: .init(.a, modifiers: [.control]))
    static let dictation = Self("dictation", default: .init(.s, modifiers: [.control]))
}
