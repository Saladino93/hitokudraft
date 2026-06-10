import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class PermissionsCoordinator {
    var accessibilityGranted = false
    var microphoneGranted = false
    var screenRecordingGranted = false

    @ObservationIgnored private var pollTimer: Timer?

    /// Called when accessibility transitions from false → true.
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    var allGranted: Bool {
        accessibilityGranted && microphoneGranted && screenRecordingGranted
    }

    init() {
        checkAccessibility()
        checkMicrophone()
        checkScreenRecording()
        startPolling()

        if !accessibilityGranted {
            requestAccessibility()
        }
    }

    func checkAccessibility() {
        let was = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        if !was && accessibilityGranted {
            onAccessibilityGranted?()
            onAccessibilityGranted = nil
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }
    }

    func requestMicrophone() async {
        microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func checkScreenRecording() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        // CGRequestScreenCaptureAccess() only shows the system prompt on the very
        // first call *ever* for this app. After denial/dismissal, macOS caches the
        // decision and subsequent calls are no-ops. Always try the API first —
        // if permission was already denied, immediately open System Settings so
        // the user can toggle it manually.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // Give the system dialog ~500ms to appear; if still not granted, open Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if !CGPreflightScreenCaptureAccess() {
                    self?.openScreenRecordingSettings()
                }
            }
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibility()
                self?.checkMicrophone()
                self?.checkScreenRecording()
                self?.stopPollingIfAllGranted()
            }
        }
        t.tolerance = 0.5  // 25% slack — no perceptible UX difference
        pollTimer = t
    }

    private func stopPollingIfAllGranted() {
        guard allGranted else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        pollTimer?.invalidate()
    }
}
