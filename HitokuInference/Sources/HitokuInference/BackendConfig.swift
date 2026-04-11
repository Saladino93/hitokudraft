import Foundation

/// Backend-specific configuration passed at model load time.
/// Use `extra` for backend-specific keys that don't belong on the shared surface.
public struct BackendConfig: Sendable {
    /// MLX: template context dict, thinking toggle, etc.
    public var templateContext: [String: Any]? {
        extra["templateContext"] as? [String: Any]
    }

    /// Whether to append a disable-thinking token (e.g. " /no_think").
    public var disableThinking: Bool

    /// Arbitrary backend-specific values.
    public var extra: [String: any Sendable]

    public init(
        disableThinking: Bool = false,
        extra: [String: any Sendable] = [:]
    ) {
        self.disableThinking = disableThinking
        self.extra = extra
    }
}
