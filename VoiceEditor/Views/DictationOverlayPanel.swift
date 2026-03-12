import AppKit
import Combine
import SwiftUI

/// HUD visual style variants.
enum HUDStyle {
    /// Ultra-clean minimal capsule: no border, very soft shadow.
    case minimal
    /// Glassy macOS capsule: ultra-subtle inner stroke, slightly more defined shadow.
    case glassy
}

/// A floating, non-activating panel that shows live dictation text
/// with an animated waveform visualization driven by real-time audio level.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    /// Change this to switch between `.minimal` and `.glassy` capsule styles.
    var style: HUDStyle = .minimal

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
        // Oversized so SwiftUI drop shadows aren't clipped by window edges
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 90

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position: keep visible capsule center at same screen position as before
        // Old: 44pt panel, origin.y = maxY - 60  →  center-y = maxY - 38
        // New: 90pt panel  →  origin.y = maxY - 38 - 45 = maxY - 83
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panelWidth / 2
            let y = frame.maxY - 83
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel, style: style)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: content.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
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
    var style: HUDStyle = .minimal

    var body: some View {
        HStack(spacing: 8) {
            WaveformBarsView(level: viewModel.audioLevel)
                .frame(width: 29, height: 16)

            Text(viewModel.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 256, height: 35)
        // 1. Properly mask the material at the source
        .background(.regularMaterial, in: Capsule())
        // 2. The shadow will now natively conform to the masked Capsule shape
        .shadow(
            color: .black.opacity(style == .glassy ? 0.25 : 0.15),
            radius: style == .glassy ? 10 : 16,
            x: 0, y: -2
        )
        .overlay {
            if style == .glassy {
                Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Waveform Bars

private struct WaveformBarsView: View {
    let level: CGFloat

    /// 5 bars with center-weighted height distribution
    private let barCount = 5

    /// Center-weighting: bars near the center are taller
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    /// Noise floor — below this, show minimum bar height
    private let noiseFloor: CGFloat = 0.05

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(
                    height: barHeight(for: index),
                    color: barColor
                )
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 2.5
        let maxHeight: CGFloat = 14.0

        guard level > noiseFloor else {
            return minHeight
        }

        let weight = weights[index]
        let height = minHeight + (maxHeight - minHeight) * level * weight
        return min(height, maxHeight)
    }

    private var barColor: Color {
        if level > noiseFloor {
            return Color(hue: 0.55, saturation: 0.9, brightness: 1.0)
        }
        return Color.white.opacity(0.3)
    }
}

private struct WaveformBar: View {
    let height: CGFloat
    let color: Color

    private let maxHeight: CGFloat = 14.0

    var body: some View {
        Capsule()
            .fill(color)
            .shadow(color: color.opacity(0.6), radius: 4, x: 0, y: 0)
            //.drawingGroup()
            .frame(width: 2.5, height: maxHeight)
            .scaleEffect(y: height / maxHeight, anchor: .center)
            .animation(.linear(duration: 0.05), value: height)
    }
}
