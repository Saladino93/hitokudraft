import SwiftUI

/// Root SwiftUI view for the overlay pill.
/// Switches between indicator + text based on the current `OverlayState`.
struct DictationOverlayContent: View {
    var viewModel: OverlayViewModel
    @AppStorage("overlayWidth") private var overlayWidth: Double = 350
    @AppStorage("overlayLineCount") private var overlayLineCount: Int = 2
    @AppStorage("dictationTheme") private var dictationThemeRaw: String = DictationTheme.default.rawValue

    private var theme: DictationTheme {
        DictationTheme(rawValue: dictationThemeRaw) ?? .default
    }

    private var capsuleWidth: CGFloat {
        CGFloat(max(150, min(overlayWidth, 500)))
    }

    private var effectiveMaxLines: Int {
        guard let state = viewModel.overlayState else { return overlayLineCount }
        switch state {
        case .listening:
            return overlayLineCount
        case .generating, .speaking, .done:
            return viewModel.isDisplayMode ? viewModel.displayModeMaxLines : max(overlayLineCount, 3)
        }
    }

    private var textAreaHeight: CGFloat {
        let lineHeight: CGFloat = 20
        return CGFloat(effectiveMaxLines) * lineHeight
    }

    var body: some View {
        if let state = viewModel.overlayState {
            VStack(spacing: 0) {
                // Main content: indicator + text
                HStack(alignment: .top, spacing: 12) {
                    indicatorView(for: state)
                    textView(for: state)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 18)

                // Bottom bar (speaking: progress, done: action buttons)
                bottomBar(for: state)
            }
            .frame(width: capsuleWidth)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor(for: state), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            // Keep a display-mode answer open while the cursor is over it,
            // so it never auto-dismisses while the user reads or scrolls.
            .onHover { hovering in
                viewModel.coordinator?.keepDisplayResultAlive(hovering)
            }
        }
    }

    // MARK: - Indicator (left side)

    @ViewBuilder
    private func indicatorView(for state: OverlayState) -> some View {
        switch state {
        case .listening:
            WaveformBarsView(viewModel: viewModel, theme: theme)
        case .generating:
            PulsingDotsView(theme: theme)
        case .speaking:
            SpeakingIndicator(theme: theme)
        case .done:
            DoneIndicator()
        }
    }

    // MARK: - Text (right side)

    @ViewBuilder
    private func textView(for state: OverlayState) -> some View {
        switch state {
        case .listening(let transcription):
            if transcription.isEmpty {
                // No placeholder text — just show the waveform until speech is detected
                Spacer().frame(maxWidth: .infinity)
            } else {
                Text(transcription)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(effectiveMaxLines)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .generating(let text):
            if text.isEmpty {
                Text("Generating...")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                OverlayTextRenderer(
                    text: text,
                    maxLines: effectiveMaxLines,
                    textAreaHeight: textAreaHeight,
                    isGhosting: true
                )
            }

        case .speaking(let text, let currentSentence, _):
            OverlayTextRenderer(
                text: text,
                maxLines: effectiveMaxLines,
                textAreaHeight: textAreaHeight,
                speakingSegment: currentSentence
            )

        case .done(let text):
            OverlayTextRenderer(
                text: text,
                maxLines: effectiveMaxLines,
                textAreaHeight: textAreaHeight
            )
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private func bottomBar(for state: OverlayState) -> some View {
        switch state {
        case .speaking(let text, _, let progress):
            VStack(spacing: 6) {
                SpeakingProgressBar(progress: progress, theme: theme)
                OverlayActionButtons(
                    text: text,
                    theme: theme,
                    isSpeaking: true,
                    onReadAloud: { viewModel.coordinator?.readAloud(text) },
                    onStop: { viewModel.coordinator?.stopReadAloud() }
                )
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

        case .done(let text):
            // Read Aloud — uses sentence-by-sentence streaming for fast first-word playback
            // and resets the overlay auto-dismiss timer to wait for TTS completion.
            OverlayActionButtons(
                text: text,
                theme: theme,
                isSpeaking: false,
                onReadAloud: { viewModel.coordinator?.readAloud(text) },
                onStop: { viewModel.coordinator?.stopReadAloud() }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))

        default:
            EmptyView()
        }
    }

    // MARK: - Theme styling

    @ViewBuilder
    private var backgroundView: some View {
        if theme.usesMaterial {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Rectangle().fill(theme.pillBackground)
        }
    }

    private func borderColor(for state: OverlayState) -> Color {
        if case .done = state {
            return theme.borderColor.opacity(0.5) // quieter in done state
        }
        return theme.borderColor
    }
}
