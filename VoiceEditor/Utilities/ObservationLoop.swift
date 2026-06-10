import Observation

/// Re-arming wrapper around `withObservationTracking` for non-View observers
/// (AppKit controllers, coordinators) that need to react to @Observable changes.
///
/// `withObservationTracking`'s `onChange` is one-shot and fires on *willSet* —
/// before the new value is visible. This helper defers the handler one main-actor
/// turn so it reads post-change values (the same reason the previous Combine
/// pipeline used `.receive(on: RunLoop.main)`), then re-arms. Rapid successive
/// mutations coalesce into a single handler call that sees the final values.
///
/// The loop ends when `isActive` returns false; observers that can re-subscribe
/// should bump a generation counter and compare it in `isActive`.
@MainActor
enum ObservationLoop {
    static func track(
        isActive: @escaping @MainActor () -> Bool,
        reading: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        guard isActive() else { return }
        withObservationTracking {
            reading()
        } onChange: {
            Task { @MainActor in
                guard isActive() else { return }
                onChange()
                track(isActive: isActive, reading: reading, onChange: onChange)
            }
        }
    }
}
