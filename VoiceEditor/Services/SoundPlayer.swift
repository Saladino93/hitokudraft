import AVFoundation

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    enum Sound: String, CaseIterable {
        case tink  = "Tink"
        case pop   = "Pop"
        case glass = "Glass"
        case ping  = "Ping"
    }

    private var players: [Sound: AVAudioPlayer] = [:]

    private init() {
        for sound in Sound.allCases {
            if let url = URL.systemSound(named: sound.rawValue) {
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    player.prepareToPlay()
                    players[sound] = player
                }
            }
        }
    }

    func play(_ sound: Sound) {
        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Plays the user-selected activation sound (empty string = muted).
    func playActivation() {
        let key = UserDefaults.standard.string(forKey: "activationSound") ?? "Tink"
        guard !key.isEmpty, let sound = Sound(rawValue: key) else { return }
        play(sound)
    }

    /// Plays the user-selected completion sound (empty string = muted).
    func playCompletion() {
        let key = UserDefaults.standard.string(forKey: "completionSound") ?? "Pop"
        guard !key.isEmpty, let sound = Sound(rawValue: key) else { return }
        play(sound)
    }
}

private extension URL {
    static func systemSound(named name: String) -> URL? {
        let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds")
        // System sounds are .aiff files
        let aiffURL = systemSoundsDir.appendingPathComponent("\(name).aiff")
        if FileManager.default.fileExists(atPath: aiffURL.path) {
            return aiffURL
        }
        return nil
    }
}
