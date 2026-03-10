import SwiftUI
import MLX
import Sparkle

@main
struct VoiceEditorApp: App {
    @StateObject private var coordinator = ConversationCoordinator()
    // @State retains the controller across App struct re-renders (App is a value type)
    @State private var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(coordinator: coordinator)
        } label: {
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator, updater: updaterController.updater)
        }
    }
}
