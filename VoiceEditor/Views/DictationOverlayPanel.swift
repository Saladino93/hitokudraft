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
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 44
        let cornerRadius: CGFloat = panelHeight / 2  // true capsule

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
        panel.hasShadow = false  // no rectangular window shadow
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position at top-center of the main screen (below menu bar)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panelWidth / 2
            let y = frame.maxY - 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let capsulePath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // Outer container: holds the shadow (not clipped)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowPath = capsulePath
        containerView.layer?.shadowColor = NSColor.black.cgColor

        switch style {
        case .minimal:
            containerView.layer?.shadowOpacity = 0.15
            containerView.layer?.shadowRadius = 16
            containerView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        case .glassy:
            containerView.layer?.shadowOpacity = 0.25
            containerView.layer?.shadowRadius = 10
            containerView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        }

        // Inner visual effect: clips content to capsule shape.
        // NSVisualEffectView ignores layer.mask for blur calculation, producing a
        // rectangular shadow artifact. maskImage is the correct API.
        let visualEffect = NSVisualEffectView(frame: containerView.bounds)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        // Clip the foreground material tint to the capsule shape
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.masksToBounds = true

        // Clip the background window-server blur (maskImage is the correct API;
        // layer.mask is ignored by NSVisualEffectView's blur compositor)
        let maskImage = NSImage(size: CGSize(width: panelWidth, height: panelHeight), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                           bottom: cornerRadius, right: cornerRadius)
        maskImage.resizingMode = .stretch
        visualEffect.maskImage = maskImage

        // Glassy variant: ultra-subtle inner stroke — added to containerView so
        // visualEffect.masksToBounds doesn't clip the outer half of the stroke line
        if style == .glassy {
            let strokeLayer = CAShapeLayer()
            strokeLayer.path = capsulePath
            strokeLayer.fillColor = nil
            strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
            strokeLayer.lineWidth = 0.5
            strokeLayer.frame = visualEffect.bounds
            containerView.layer?.addSublayer(strokeLayer)
        }

        containerView.addSubview(visualEffect)

        let hostingView = NSHostingView(rootView: DictationOverlayContent(viewModel: viewModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])
        panel.contentView = containerView
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
        HStack(spacing: 10) {
            // Waveform bars
            WaveformBarsView(level: viewModel.audioLevel)
                .frame(width: 36, height: 20)

            // Transcription text
            Text(viewModel.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        let maxHeight: CGFloat = 18.0

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

    private let maxHeight: CGFloat = 18.0

    var body: some View {
        Capsule()
            .fill(color)
            .shadow(color: color.opacity(0.6), radius: 4, x: 0, y: 0)
            .drawingGroup()
            .frame(width: 3, height: maxHeight)
            .scaleEffect(y: height / maxHeight, anchor: .center)
            .animation(.linear(duration: 0.05), value: height)
    }
}
