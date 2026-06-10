import SwiftUI
import MLX
import Sparkle
import UserNotifications

@main
struct VoiceEditorApp: App {
    @State private var coordinator = ConversationCoordinator()
    // @State retains the controller across App struct re-renders (App is a value type)
    @State private var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        // Register delegate before any notification is scheduled so it's in place
        // when TimerService fires (macOS drops notifications to nil delegate).
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        Self.applyOneTimeMigrations()
        WhatsNewWindowController.checkAndShowIfNeeded()
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

        // v1.1.0: Use slightly longer silence timeout to avoid premature cutoff.
        if !defaults.bool(forKey: "migration_v110_silence_defaults") {
            defaults.set(1.5, forKey: "silenceDurationLimit")
            defaults.set(3.5, forKey: "noSpeechTimeout")
            defaults.set("Tink", forKey: "activationSound")
            defaults.set("Pop", forKey: "completionSound")
            defaults.set(true, forKey: "migration_v110_silence_defaults")
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
