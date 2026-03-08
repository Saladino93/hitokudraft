import Foundation

/// A thread-safe wrapper around a float array to prevent data races between
/// the audio engine (background thread) and the main thread.
final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var buffer: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: newSamples)
    }

    func clear(keepingCapacity: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Returns the first `count` samples without clearing.
    /// If the buffer has fewer samples, returns everything available.
    func getPrefix(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(buffer.prefix(count))
    }
}
