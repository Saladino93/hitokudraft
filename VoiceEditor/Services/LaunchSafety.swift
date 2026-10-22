import AppKit
import CoreML
import Foundation
import os

/// Cross-launch crash recovery for launch-time model warm-up.
///
/// Core ML compiles GPU-bound models through MPSGraph/MLIR. When that compiler
/// fails (observed on macOS 27.2 / M5 Pro with the Kokoro TTS models: "MLIR pass
/// failed") the framework calls `abort()`. That SIGABRT happens inside Apple's code
/// and cannot be caught by Swift `do/catch`, so there is no in-process fallback.
///
/// Recovery therefore has to span launches: a UserDefaults flag is set before
/// launch-time model loading starts and cleared once all of it has finished
/// (successfully or with a caught error). If the flag is still set when the app
/// next launches, the previous process died mid-warm-up, so this session skips
/// the TTS pre-warm and loads TTS models with CPU-only compute units.
enum LaunchSafety {

    private static let flagKey = "launchModelWarmupInProgress"
    private static let log = Logger(subsystem: "com.hitokudraft.app", category: "LaunchSafety")

    /// Snapshot of the flag left behind by the previous process.
    ///
    /// Evaluated once, on first access. It must be read before `beginRiskyLaunchWork()`
    /// overwrites the flag; `beginRiskyLaunchWork()` touches it first to guarantee that.
    static let previousLaunchCrashedDuringWarmup: Bool = {
        let crashed = UserDefaults.standard.bool(forKey: flagKey)
        if crashed {
            log.warning("Previous launch did not finish model warm-up; using safe compute units and skipping pre-warm this session")
        }
        return crashed
    }()

    /// True when GPU compilation of Core ML models should be avoided this session:
    /// either the previous launch crashed mid-warm-up, or the OS is one where
    /// MPSGraph compilation of the TTS models is known to abort (macOS 27+).
    static var preferSafeComputeUnits: Bool {
        previousLaunchCrashedDuringWarmup
            || ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// Compute units for the Kokoro TTS models. `.cpuAndGPU` is FluidAudio's default
    /// (keeps synthesis fast on macOS 26 and earlier); `.cpuOnly` avoids MPSGraph entirely.
    static var ttsComputeUnits: MLComputeUnits {
        preferSafeComputeUnits ? .cpuOnly : .cpuAndGPU
    }

    /// Number of overlapping launch-work windows (e.g. a manual "Download & Set Up"
    /// while the initial setup is still warming up). The flag is cleared only when
    /// the last one ends.
    @MainActor private static var activeWindows = 0

    /// Set once the termination observer has been registered.
    @MainActor private static var terminationObserverInstalled = false

    /// A normal quit during a long first-run download is not a crash, so the next launch must not enter safe mode.
    @MainActor private static func installTerminationObserver() {
        guard !terminationObserverInstalled else { return }
        terminationObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            UserDefaults.standard.set(false, forKey: flagKey)
        }
    }

    /// Marks the start of launch-time model loading. Call before any model load begins.
    @MainActor static func beginRiskyLaunchWork() {
        _ = previousLaunchCrashedDuringWarmup  // snapshot the old value before overwriting it
        installTerminationObserver()
        activeWindows += 1
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// Marks the end of launch-time model loading. Call once every launch-time load
    /// (including the TTS pre-warm, if any) has completed or failed.
    @MainActor static func endRiskyLaunchWork() {
        activeWindows = max(0, activeWindows - 1)
        guard activeWindows == 0 else { return }
        UserDefaults.standard.set(false, forKey: flagKey)
    }

    /// Human-readable name for logging.
    static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        @unknown default: return "unknown(\(units.rawValue))"
        }
    }
}
