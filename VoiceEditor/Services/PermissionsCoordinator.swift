import AppKit
import AVFoundation
import Combine

@MainActor
final class PermissionsCoordinator: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var microphoneGranted = false
    @Published var screenRecordingGranted = false

    private var pollTimer: Timer?

    /// Called when accessibility transitions from false → true.
    var onAccessibilityGranted: (() -> Void)?

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

    /// Tracks whether we've already called CGRequestScreenCaptureAccess once.
    /// The API only shows the system prompt on the first call; after that it's a no-op.
    private var screenRecordingRequested = false

    func requestScreenRecording() {
        if screenRecordingRequested {
            // Already prompted once — open System Settings directly
            openScreenRecordingSettings()
        } else {
            screenRecordingRequested = true
            CGRequestScreenCaptureAccess()
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
