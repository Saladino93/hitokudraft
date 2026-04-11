import Foundation
import CoreGraphics

/// A unified request that can carry text, audio, and/or images.
/// Backends inspect only the fields they support (see `InferenceBackend.supportedModalities`).
public struct InferenceRequest: Sendable {
    public var systemPrompt: String?
    public var text: String?
    public var audio: Data?           // Raw PCM or encoded (WAV/FLAC)
    public var images: [CGImage]?
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float?
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int?
    public var kvBits: Int?

    public init(
        systemPrompt: String? = nil,
        text: String? = nil,
        audio: Data? = nil,
        images: [CGImage]? = nil,
        maxTokens: Int = 2048,
        temperature: Float = 0.7,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        kvBits: Int? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.text = text
        self.audio = audio
        self.images = images
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.kvBits = kvBits
    }
}
