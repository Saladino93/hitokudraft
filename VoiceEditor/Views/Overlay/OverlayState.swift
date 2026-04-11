import Foundation

/// The four visual states of the overlay pill.
/// Derived by `OverlayViewModel` from the coordinator's published properties.
enum OverlayState: Equatable {
    /// User is speaking — waveform bars + live transcription.
    case listening(transcription: String)

    /// LLM is producing a response — pulsing dots + streaming text.
    case generating(text: String)

    /// TTS is reading the response aloud — sentence highlighting + progress bar.
    case speaking(text: String, currentSentence: String, progress: Double)

    /// Response complete — static text + action buttons (copy, read aloud).
    case done(text: String)

    /// The text content for any state.
    var text: String {
        switch self {
        case .listening(let t): return t
        case .generating(let t): return t
        case .speaking(let t, _, _): return t
        case .done(let t): return t
        }
    }
}
