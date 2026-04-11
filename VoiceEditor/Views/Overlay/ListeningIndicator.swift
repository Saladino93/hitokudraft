import SwiftUI

/// 5 animated waveform bars driven by audio level + sine oscillation.
struct WaveformBarsView: View {
    let audioLevel: CGFloat
    let theme: DictationTheme
    let tick: Date  // drives re-render at 30fps

    private static let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2.5
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 16

    // Incommensurate frequencies for organic motion
    private static let frequencies: [Double] = [2.8, 3.6, 4.2, 3.0, 4.5]
    private static let phaseOffsets: [Double] = [0.0, 0.9, 1.7, 2.5, 3.4]
    private static let smoothingAlphas: [CGFloat] = [0.15, 0.20, 0.25, 0.22, 0.18]

    @State private var barHeights: [CGFloat] = Array(repeating: minHeight, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: Self.barWidth / 2)
                    .fill(theme.accentColor)
                    .frame(width: Self.barWidth, height: barHeights[i])
                    .shadow(color: theme.accentColor.opacity(isActive ? 0.6 : 0.15),
                            radius: isActive ? 4 : 1)
            }
        }
        .frame(width: CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing,
               height: Self.maxHeight)
        .onChange(of: tick) { updateBars() }
        .onAppear { updateBars() }
    }

    private var isActive: Bool { audioLevel > 0.05 }

    private func updateBars() {
        let time = Date().timeIntervalSinceReferenceDate
        for i in 0..<Self.barCount {
            let target: CGFloat
            if isActive {
                let sine = sin(time * Self.frequencies[i] * .pi * 2 + Self.phaseOffsets[i])
                target = Self.minHeight + (Self.maxHeight - Self.minHeight) * audioLevel * CGFloat(sine * 0.5 + 0.5)
            } else {
                // Idle breathing pulse
                let sine = sin(time * 0.3 * .pi * 2 + Self.phaseOffsets[i])
                target = Self.minHeight + 1.5 * CGFloat(sine * 0.5 + 0.5)
            }
            barHeights[i] += Self.smoothingAlphas[i] * (target - barHeights[i])
        }
    }
}

/// Optional "LISTENING" badge above the pill.
struct ListeningBadge: View {
    let theme: DictationTheme

    var body: some View {
        Text("LISTENING")
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(theme.badgeText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.badgeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
