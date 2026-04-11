import Foundation
import Testing
@testable import HitokuInference

// MARK: - Mock backend for testing

private final class MockBackend: InferenceBackend, @unchecked Sendable {
    let supportedModalities: Set<InputModality>
    var isLoaded: Bool
    var generateCalled = false

    init(modalities: Set<InputModality>, loaded: Bool = true) {
        self.supportedModalities = modalities
        self.isLoaded = loaded
    }

    func loadModel(at path: String, config: BackendConfig) async throws {
        isLoaded = true
    }

    func unload() {
        isLoaded = false
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        generateCalled = true
        return AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Tests

@Test func routerResolvesPreferredBackend() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text, .image])
    let litert = MockBackend(modalities: [.text, .audio, .image])
    router.register(mlx, as: "mlx")
    router.register(litert, as: "litert")
    router.preferred = "litert"

    let req = InferenceRequest(text: "Hello")
    let result = router.resolve(for: req)
    #expect(result?.0 == "litert")
}

@Test func routerFallsBackToModalityMatch() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text, .image])
    let litert = MockBackend(modalities: [.text, .audio, .image])
    router.register(mlx, as: "mlx")
    router.register(litert, as: "litert")
    // No preferred set

    // Audio request → should pick litert (covers .audio)
    let req = InferenceRequest(text: "edit this", audio: Data([0x00]))
    let result = router.resolve(for: req)
    #expect(result?.0 == "litert")
}

@Test func routerFallsBackToAnyLoaded() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text])
    router.register(mlx, as: "mlx")

    // Audio request, but only text backend available → still resolves (caller handles STT)
    let req = InferenceRequest(audio: Data([0x00]))
    let result = router.resolve(for: req)
    #expect(result?.0 == "mlx")
}

@Test func routerReturnsNilWhenNothingLoaded() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text], loaded: false)
    router.register(mlx, as: "mlx")

    let req = InferenceRequest(text: "Hello")
    let result = router.resolve(for: req)
    #expect(result == nil)
}

@Test func routerSkipsUnloadedPreferred() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text, .image])
    let litert = MockBackend(modalities: [.text, .audio, .image], loaded: false)
    router.register(mlx, as: "mlx")
    router.register(litert, as: "litert")
    router.preferred = "litert"

    let req = InferenceRequest(text: "Hello")
    let result = router.resolve(for: req)
    // litert is preferred but not loaded → should fall back to mlx
    #expect(result?.0 == "mlx")
}

@Test func routerUnloadRemovesBackend() {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text])
    router.register(mlx, as: "mlx")
    #expect(router.registeredKeys.count == 1)

    let removed = router.remove("mlx")
    #expect(removed != nil)
    #expect(mlx.isLoaded == false)
    #expect(router.registeredKeys.isEmpty)
}

@Test func routerSupportedModalitiesIsUnion() {
    let router = InferenceRouter()
    router.register(MockBackend(modalities: [.text]), as: "a")
    router.register(MockBackend(modalities: [.audio, .image]), as: "b")
    #expect(router.supportedModalities == [.text, .audio, .image])
}

@Test func routerGenerateProxiesToResolved() async throws {
    let router = InferenceRouter()
    let mlx = MockBackend(modalities: [.text])
    router.register(mlx, as: "mlx")

    let req = InferenceRequest(text: "Hello")
    for try await _ in router.generate(request: req) {}
    #expect(mlx.generateCalled)
}
