import SwiftUI
import MLX

@main
struct VoiceEditorApp: App {
    @StateObject private var coordinator = ConversationCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(coordinator: coordinator)
        } label: {
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
