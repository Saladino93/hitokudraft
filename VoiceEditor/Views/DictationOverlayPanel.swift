import AppKit
import Combine
import SwiftUI

/// A floating, non-activating panel that shows live dictation text
/// with an animated waveform visualization driven by real-time audio level.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    func show(text: String) {
        viewModel.text = text

        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    /// Start polling audio level from a ContinuousSession at ~30fps.
    func startLevelPolling(session: AudioCaptureService.ContinuousSession) {
        viewModel.startPolling(session: session)
    }

    func hide() {
        viewModel.stopPolling()
        panel?.orderOut(nil)
        panel = nil
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position at top-center of the main screen (below menu bar)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - 210
            let y = frame.maxY - 70
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.contentView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel)
        )
        self.panel = panel
    }
}

// MARK: - ViewModel

@MainActor
private final class OverlayViewModel: ObservableObject {
    @Published var text: String = "Dictating..."
    @Published var audioLevel: CGFloat = 0

    private var displayLink: CVDisplayLink?
    private weak var session: AudioCaptureService.ContinuousSession?
    private var timer: Timer?

    func startPolling(session: AudioCaptureService.ContinuousSession) {
        self.session = session
        // Use a Timer at ~30fps to read the thread-safe audioLevel
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollLevel()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        session = nil
        audioLevel = 0
    }

    private func pollLevel() {
        guard let session else {
            audioLevel = 0
            return
        }
        // Map RMS (typically 0..0.3 for speech) to 0..1 range
        let raw = CGFloat(session.audioLevel)
        let normalized = min(raw / 0.15, 1.0)
        audioLevel = normalized
    }
}

// MARK: - Overlay View

private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Waveform bars
            WaveformBarsView(level: viewModel.audioLevel)
                .frame(width: 50, height: 24)

            // Transcription text
            Text(viewModel.text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.82))
        )
    }
}

// MARK: - Waveform Bars

private struct WaveformBarsView: View {
    let level: CGFloat

    /// 7 bars with center-weighted height distribution
    private let barCount = 7

    /// Center-weighting: bars near the center are taller
    private let weights: [CGFloat] = [0.4, 0.65, 0.85, 1.0, 0.85, 0.65, 0.4]

    /// Noise floor — below this, show minimum bar height
    private let noiseFloor: CGFloat = 0.05

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(
                    height: barHeight(for: index),
                    color: barColor
                )
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 3.0
        let maxHeight: CGFloat = 22.0

        guard level > noiseFloor else {
            return minHeight
        }

        let weight = weights[index]
        let height = minHeight + (maxHeight - minHeight) * level * weight
        return min(height, maxHeight)
    }

    private var barColor: Color {
        if level > noiseFloor {
            return .red
        }
        return .gray
    }
}

private struct WaveformBar: View {
    let height: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 3, height: height)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: height)
    }
}
