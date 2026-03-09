import AppKit
import AVFoundation
import Combine

@MainActor
final class PermissionsCoordinator: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var microphoneGranted = false

    private var pollTimer: Timer?

    /// Called when accessibility transitions from false → true.
    var onAccessibilityGranted: (() -> Void)?

    var allGranted: Bool {
        accessibilityGranted && microphoneGranted
    }

    init() {
        checkAccessibility()
        checkMicrophone()
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

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibility()
                self?.checkMicrophone()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}
