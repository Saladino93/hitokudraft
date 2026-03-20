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

    init() {
        Self.applyOneTimeMigrations()
    }

    /// One-time default overrides applied on upgrade.
    /// Each migration key ensures it runs only once per device.
    private static func applyOneTimeMigrations() {
        let defaults = UserDefaults.standard

        // v1.0.9: VAD makes old silence/no-speech defaults feel sluggish.
        if !defaults.bool(forKey: "migration_v109_vad_defaults") {
            defaults.set(0.5, forKey: "silenceDurationLimit")
            defaults.set(3.0, forKey: "noSpeechTimeout")
            defaults.set(true, forKey: "migration_v109_vad_defaults")
        }
    }

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
