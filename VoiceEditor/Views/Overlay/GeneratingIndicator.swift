import SwiftUI

/// 3 pulsing dots indicating LLM generation is in progress.
struct PulsingDotsView: View {
    let theme: DictationTheme

    private static let dotCount = 3
    private static let dotSize: CGFloat = 5

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.dotCount, id: \.self) { i in
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .scaleEffect(isAnimating ? 1.2 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 1.2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 25, height: 16)
        .onAppear { isAnimating = true }
    }
}
