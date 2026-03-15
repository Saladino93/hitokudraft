import AppKit
import Combine
import SwiftUI


/// HUD visual style variants.
enum HUDStyle {
    /// Ultra-clean minimal capsule: no border, very soft shadow.
    case minimal
    /// Glassy macOS capsule: ultra-subtle inner stroke, slightly more defined shadow.
    case glassy
    /// Ghost pill: nearly invisible, heavy blur, wallpaper bleed-through.
    case ghost
}


/// A floating, non-activating panel that shows live dictation text
/// with an animated waveform visualization driven by real-time audio level.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()


    /// Change this to switch between `.minimal`, `.glassy`, and `.ghost` capsule styles.
    var style: HUDStyle = .ghost


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
        let raw = CGFloat(session.audioLevel)
        let normalized = min(raw / 0.15, 1.0)
        audioLevel = normalized
    }
}


// MARK: - Overlay View


private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: OverlayViewModel
    var style: HUDStyle = .ghost


    var body: some View {
        HStack(spacing: 8) {
            WaveformBarsView(level: viewModel.audioLevel)
                .frame(width: 29, height: 16)


            Text(viewModel.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: 256, height: 35)
        .background {
            switch style {
            case .ghost:
                // Ghost pill: ultra-transparent white tint + heavy blur
                Capsule()
                    .fill(.white.opacity(0.18))
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    .clipShape(Capsule())

            case .minimal:
                Capsule()
                    .fill(.regularMaterial)

            case .glassy:
                Capsule()
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            switch style {
            case .ghost:
                // Barely-visible white inner stroke
                Capsule()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)

            case .glassy:
                Capsule()
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)

            case .minimal:
                EmptyView()
            }
        }
        // Ghost: no shadow at all — the pill should vanish into the wallpaper
        // Minimal/Glassy: keep their existing shadow behavior
        .shadow(
            color: .black.opacity(style == .ghost ? 0 : (style == .glassy ? 0.25 : 0.15)),
            radius: style == .ghost ? 0 : (style == .glassy ? 10 : 16),
            x: 0, y: -2
        )
    }
}


// MARK: - Waveform Bars


private struct WaveformBarsView: View {
    let level: CGFloat


    private let barCount = 5
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]
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
            .frame(width: 2.5, height: maxHeight)
            .scaleEffect(y: height / maxHeight, anchor: .center)
            .animation(.linear(duration: 0.05), value: height)
    }
}