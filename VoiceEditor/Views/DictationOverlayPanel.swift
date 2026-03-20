import AppKit
import Combine
import SwiftUI


/// A floating, non-activating panel that shows live dictation text
/// with an animated waveform visualization driven by real-time audio level.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    private var theme: DictationTheme { .current }

    func show(text: String, isStatus: Bool = false) {
        viewModel.text = text
        viewModel.isStatus = isStatus
        viewModel.showText = (UserDefaults.standard.object(forKey: "showDictationText") as? Bool) ?? true

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
        // Oversized so SwiftUI drop shadows / neon glow aren't clipped by window edges
        let capsuleWidth: CGFloat = 192
        let panelWidth: CGFloat = capsuleWidth + 16
        let panelHeight: CGFloat = 68

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

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panelWidth / 2
            let y = frame.maxY - 68
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel, theme: theme)
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
    @Published var showText: Bool = (UserDefaults.standard.object(forKey: "showDictationText") as? Bool) ?? true
    @Published var isStatus: Bool = false
    @Published var tick = Date()

    private var displayLink: CVDisplayLink?
    private weak var session: AudioCaptureService.ContinuousSession?
    private var timer: Timer?

    func startPolling(session: AudioCaptureService.ContinuousSession) {
        self.session = session
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollLevel()
            self.tick = Date()
        }
        t.tolerance = (1.0 / 30.0) * 0.1  // 10% slack for timer coalescing
        timer = t
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
        let raw = CGFloat(session.audioLevel)
        let normalized = min(raw / 0.15, 1.0)
        audioLevel = normalized
    }
}


// MARK: - Overlay View


private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: OverlayViewModel
    var theme: DictationTheme

    /// Show text only when the setting is on AND this isn't a bare status message.
    private var effectiveShowText: Bool {
        viewModel.showText && !viewModel.isStatus
    }

    var body: some View {
        HStack(spacing: 8) {
            WaveformBarsView(level: viewModel.audioLevel, date: viewModel.tick, theme: theme)
                .frame(width: 29, height: 16)

            if effectiveShowText {
                Text(viewModel.text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: effectiveShowText ? 192 : 64, height: 35)
        .background {
            Capsule()
                .fill(theme.panelBackground)
        }
        .overlay {
            Capsule()
                .strokeBorder(theme.panelBorder, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: effectiveShowText)
    }
}


// MARK: - Waveform Bars


private struct WaveformBarsView: View {
    let level: CGFloat
    let date: Date
    var theme: DictationTheme

    private static let barCount = 7
    private static let minHeight: CGFloat = 2.5
    private static let maxHeight: CGFloat = 14.0

    // Incommensurate frequencies ensure bars never synchronize
    private static let frequencies: [Double] = [2.8, 3.6, 4.2, 3.0, 4.5, 3.3, 2.5]
    // Staggered phase offsets per bar
    private static let phaseOffsets: [Double] = [0.0, 0.9, 1.7, 2.5, 3.4, 4.1, 5.0]
    // Different smoothing alphas create a "settling cascade" after speech stops
    private static let smoothingAlphas: [CGFloat] = [0.15, 0.20, 0.25, 0.22, 0.18, 0.23, 0.16]
    // Idle breathing frequency
    private static let breathFrequency: Double = 0.3

    @State private var smoothedHeights: [CGFloat] = Array(
        repeating: WaveformBarsView.minHeight, count: WaveformBarsView.barCount
    )

    var body: some View {
        HStack(spacing: 2.0) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(level > 0.05 ? theme.accent : theme.accent.opacity(0.3))
                    .shadow(color: theme.accent.opacity(level > 0.05 ? 0.6 : 0.15), radius: 4)
                    .frame(width: 2.0, height: smoothedHeights[i])
            }
        }
        .onChange(of: date) { _, newDate in
            updateHeights(at: newDate)
        }
    }

    private func updateHeights(at now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        var newHeights = smoothedHeights

        for i in 0..<Self.barCount {
            let target: CGFloat
            if level > 0.05 {
                // Sine oscillator modulated by audio level
                let sine = sin(2.0 * .pi * Self.frequencies[i] * t + Self.phaseOffsets[i])
                let oscillation = 0.5 + 0.5 * sine // normalize to 0…1
                target = Self.minHeight + (Self.maxHeight - Self.minHeight) * level * CGFloat(oscillation)
            } else {
                // Idle breathing: slow sine pulse keeps bars alive
                let breath = sin(2.0 * .pi * Self.breathFrequency * t + Self.phaseOffsets[i])
                let pulse = 0.5 + 0.5 * breath // normalize to 0…1
                target = Self.minHeight + 1.5 * CGFloat(pulse)
            }

            // Per-bar exponential smoothing
            let alpha = Self.smoothingAlphas[i]
            newHeights[i] = newHeights[i] + alpha * (target - newHeights[i])
        }

        smoothedHeights = newHeights
    }
}
