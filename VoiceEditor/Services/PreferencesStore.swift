import FluidAudio
import Foundation

/// Centralized read-only access to user preferences stored in UserDefaults.
///
/// Eliminates scattered `UserDefaults.standard` calls throughout the codebase.
/// Each property reads the current value from UserDefaults at call time —
/// no caching, so changes from SettingsView are picked up immediately.
struct PreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Context & Pipeline

    var contextAwareMode: ContextAwareMode {
        let raw = defaults.string(forKey: "contextAwareMode") ?? "off"
        return ContextAwareMode(rawValue: raw) ?? .off
    }

    var polishDictation: Bool {
        defaults.bool(forKey: "polishDictation")
    }

    var internetAccessEnabled: Bool {
        defaults.bool(forKey: "internetAccessEnabled")
    }

    // MARK: - TTS

    var ttsEnabled: Bool {
        defaults.bool(forKey: "ttsEnabled")
    }

    var ttsBackend: TtsBackend {
        let raw = defaults.string(forKey: "ttsBackend") ?? "kokoro"
        return raw == "pocketTts" ? .pocketTts : .kokoro
    }

    var ttsVoice: String {
        defaults.string(forKey: "ttsVoice") ?? TtsConstants.recommendedVoice
    }

    var ttsSpeed: Float {
        let raw = defaults.double(forKey: "ttsSpeed")
        return Float(raw > 0 ? raw : 1.0)
    }

    /// Snapshot of all TTS settings for passing through a pipeline.
    struct TTSSettings {
        let enabled: Bool
        let backend: TtsBackend
        let voice: String
        let speed: Float
    }

    var ttsSettings: TTSSettings {
        TTSSettings(enabled: ttsEnabled, backend: ttsBackend, voice: ttsVoice, speed: ttsSpeed)
    }
}
