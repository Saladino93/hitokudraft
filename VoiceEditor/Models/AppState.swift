import SwiftUI

enum AppState: Equatable {
    case idle
    case downloading(progress: Double)
    case warmingUp
    case listening
    case transcribing
    case generating
    case pasting
    case dictating(String)
    case error(String)

    var isProcessing: Bool {
        switch self {
        case .listening, .transcribing, .generating, .pasting, .dictating:
            return true
        default:
            return false
        }
    }
}

enum VoiceEditorError: LocalizedError {
    case emptyTranscription
    case emptyOutput
    case modelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .emptyTranscription: return "No speech detected"
        case .emptyOutput: return "LLM returned empty output"
        case .modelsNotLoaded: return "Models not loaded yet"
        }
    }
}
