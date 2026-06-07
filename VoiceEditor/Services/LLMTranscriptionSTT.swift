import Foundation

/// An `STTService` backed by an audio-capable LLM (Gemma 4), used as an optional
/// transcriber for file transcription. Gemma is strong on mixed and many
/// languages, so this is the better choice for multilingual material, at the cost
/// of being slower than a dedicated ASR.
///
/// Each call sends the audio chunk to the model with a strict verbatim prompt.
final class LLMTranscriptionSTT: STTService, @unchecked Sendable {
    private let llm: any LLMService

    /// Kept short and strict so the model returns the transcription, not a reply.
    private static let prompt =
        "Transcribe the audio verbatim. Output only the spoken words as text, with no commentary, labels, translations, or quotation marks. If there is no speech, output nothing."

    init(llm: any LLMService) {
        self.llm = llm
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let wav = AudioEncoder.wavData(from: samples)
        // Generous token budget: ~30 s of speech can be a few hundred words.
        let maxTokens = 1024
        var raw = ""
        for try await chunk in llm.generateStream(prompt: Self.prompt, audio: wav, maxTokens: maxTokens) {
            raw += chunk
        }
        return OutputCleaner.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
