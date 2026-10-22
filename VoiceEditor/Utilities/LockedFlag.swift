import os

/// A thread-safe boolean flag. Lock-backed, so it can be read and written from any
/// isolation domain, including the real-time audio tap callback.
final class LockedFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var value: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }

    func reset() { state.withLock { $0 = false } }

    /// Atomically sets the flag. Returns `true` only for the caller that flipped it
    /// from clear to set, so exactly one caller wins a test-and-set race.
    func setIfClear() -> Bool {
        state.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
}
