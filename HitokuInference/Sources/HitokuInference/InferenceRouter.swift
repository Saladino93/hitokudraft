import Foundation

/// Routes inference requests to the best available backend.
///
/// Register one or more backends by name, optionally set a preferred backend,
/// and call `generate(request:)` — the router picks the right one.
///
/// Resolution order:
/// 1. Preferred backend (if set, loaded, and supports the request's modalities)
/// 2. Best-fit loaded backend whose `supportedModalities` covers the request
/// 3. Any loaded backend (fallback — lets text-only backends handle audio requests
///    when no native audio backend is available; caller handles STT upstream)
///
/// Conforms to `InferenceBackend` itself, so callers can treat it as a single backend.
///
/// Thread-safety: registration happens on the main actor while resolution runs
/// inside generation tasks and detached unload blocks, so all access to the
/// backend table goes through `lock`. Backend calls (`unload`, `loadModel`,
/// `generate`) are made outside the lock to avoid holding it across slow work.
public final class InferenceRouter: @unchecked Sendable {

    // MARK: - State

    private let lock = NSLock()
    private var backends: [String: any InferenceBackend] = [:]
    private var _preferred: String?

    /// The user's explicitly preferred backend key. `nil` means auto-resolve.
    public var preferred: String? {
        get { lock.withLock { _preferred } }
        set { lock.withLock { _preferred = newValue } }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Registration

    /// Register a backend under a unique key (e.g. "mlx", "litert").
    public func register(_ backend: any InferenceBackend, as key: String) {
        lock.withLock { backends[key] = backend }
    }

    /// Remove a backend by key. Calls `unload()` on it first.
    @discardableResult
    public func remove(_ key: String) -> (any InferenceBackend)? {
        guard let backend = lock.withLock({ backends.removeValue(forKey: key) }) else { return nil }
        backend.unload()
        return backend
    }

    /// All registered backend keys.
    public var registeredKeys: [String] { lock.withLock { Array(backends.keys) } }

    /// Returns the backend registered under `key`, or nil.
    public func backend(for key: String) -> (any InferenceBackend)? {
        lock.withLock { backends[key] }
    }

    // MARK: - Resolution

    /// Determine which modalities the request actually needs.
    private func requestedModalities(for request: InferenceRequest) -> Set<InputModality> {
        var needed: Set<InputModality> = []
        if request.text != nil { needed.insert(.text) }
        if request.audio != nil { needed.insert(.audio) }
        if let imgs = request.images, !imgs.isEmpty { needed.insert(.image) }
        // If nothing explicit, assume text (prompt-only requests)
        if needed.isEmpty { needed.insert(.text) }
        return needed
    }

    /// Resolve the best backend for a request.
    /// Returns `(key, backend)` or nil if nothing is loaded.
    public func resolve(for request: InferenceRequest) -> (String, any InferenceBackend)? {
        let needed = requestedModalities(for: request)
        let (snapshot, preferredKey) = lock.withLock { (backends, _preferred) }

        // 1. Preferred backend — if set, loaded, and covers all needed modalities
        if let key = preferredKey,
           let backend = snapshot[key],
           backend.isLoaded,
           needed.isSubset(of: backend.supportedModalities) {
            return (key, backend)
        }

        // 2. Best-fit: loaded backend that covers ALL needed modalities
        //    Prefer the one with the fewest extra modalities (most specialized).
        let bestFit = snapshot
            .filter { $0.value.isLoaded && needed.isSubset(of: $0.value.supportedModalities) }
            .min { $0.value.supportedModalities.count < $1.value.supportedModalities.count }

        if let match = bestFit {
            return (match.key, match.value)
        }

        // 3. Fallback: any loaded backend (caller is responsible for pre-processing,
        //    e.g. running STT before sending to a text-only backend)
        if let fallback = snapshot.first(where: { $0.value.isLoaded }) {
            return (fallback.key, fallback.value)
        }

        return nil
    }
}

// MARK: - InferenceBackend conformance

extension InferenceRouter: InferenceBackend {

    /// Union of all registered backends' modalities.
    public var supportedModalities: Set<InputModality> {
        let snapshot = lock.withLock { Array(backends.values) }
        return snapshot.reduce(into: Set<InputModality>()) { result, backend in
            result.formUnion(backend.supportedModalities)
        }
    }

    /// True if any registered backend is loaded.
    public var isLoaded: Bool {
        let snapshot = lock.withLock { Array(backends.values) }
        return snapshot.contains { $0.isLoaded }
    }

    /// Load a model on the preferred backend (or first registered).
    /// For multi-backend setups, load each backend individually via `backend(for:)`.
    public func loadModel(at path: String, config: BackendConfig) async throws {
        let backend = lock.withLock { () -> (any InferenceBackend)? in
            guard let key = _preferred ?? backends.keys.first else { return nil }
            return backends[key]
        }
        guard let backend else {
            throw RouterError.noBackendRegistered
        }
        try await backend.loadModel(at: path, config: config)
    }

    /// Unload all registered backends.
    public func unload() {
        let snapshot = lock.withLock { Array(backends.values) }
        for backend in snapshot {
            backend.unload()
        }
    }

    /// Route and generate.
    public func generate(request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        guard let (_, backend) = resolve(for: request) else {
            return AsyncThrowingStream { $0.finish(throwing: RouterError.noLoadedBackend) }
        }
        return backend.generate(request: request)
    }
}

// MARK: - Errors

public enum RouterError: LocalizedError {
    case noBackendRegistered
    case noLoadedBackend

    public var errorDescription: String? {
        switch self {
        case .noBackendRegistered:
            return "No inference backend is registered with the router."
        case .noLoadedBackend:
            return "No loaded inference backend is available to handle this request."
        }
    }
}
