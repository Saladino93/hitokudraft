import KeyboardShortcuts

@MainActor
final class HotkeyManager {
    private weak var coordinator: ConversationCoordinator?

    init(coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
        setupHotkeys()
    }

    private func setupHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .voiceEdit) { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            Task { @MainActor in
                await coordinator.handleVoiceEdit()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .grammarFix) { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            Task { @MainActor in
                await coordinator.handleGrammarFix()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            Task { @MainActor in
                await coordinator.handleDictation()
            }
        }
    }
}
