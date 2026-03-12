import Foundation
import os

/// A high-performance thread-safe buffer for accumulating Float audio samples.
/// Uses OSAllocatedUnfairLock (a spin lock) for synchronous, low-latency access
/// from real-time CoreAudio tap callbacks where await is not permitted.
final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = OSAllocatedUnfairLock()

    func append(_ newSamples: [Float]) {
        lock.withLock {
            samples.append(contentsOf: newSamples)
        }
    }

    func clear(keepingCapacity: Bool = false) {
        lock.withLock {
            samples.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    var count: Int {
        lock.withLock { samples.count }
    }

    func getAll() -> [Float] {
        lock.withLock { samples }
    }

    func getPrefix(_ count: Int) -> [Float] {
        lock.withLock { Array(samples.prefix(count)) }
    }

    /// Returns samples from `startIndex` to the end of the buffer.
    /// Used by streaming STT to read only new audio since last feed.
    func getSuffix(from startIndex: Int) -> [Float] {
        lock.withLock {
            guard startIndex < samples.count else { return [] }
            return Array(samples[startIndex...])
        }
    }
}
