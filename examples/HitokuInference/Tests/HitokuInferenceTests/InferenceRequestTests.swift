import Testing
@testable import HitokuInference

@Test func requestDefaults() {
    let req = InferenceRequest(text: "Hello")
    #expect(req.maxTokens == 2048)
    #expect(req.temperature == 0.7)
    #expect(req.kvBits == nil)
    #expect(req.images == nil)
    #expect(req.audio == nil)
}

@Test func modalitySet() {
    let modalities: Set<InputModality> = [.text, .image]
    #expect(modalities.contains(.text))
    #expect(!modalities.contains(.audio))
}
