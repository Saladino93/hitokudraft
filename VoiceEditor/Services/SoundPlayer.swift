import AVFoundation

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    enum Sound: String, CaseIterable {
        case tink = "Tink"
        case pop = "Pop"
        case glass = "Glass"
    }

    private var players: [Sound: AVAudioPlayer] = [:]

    private init() {
        // Pre-load all sounds at init
        for sound in Sound.allCases {
            if let url = URL.systemSound(named: sound.rawValue) {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.prepareToPlay()
                    players[sound] = player
                } catch {
                    // Sound will simply not play — non-fatal
                }
            }
        }
    }

    func play(_ sound: Sound) {
        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
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
