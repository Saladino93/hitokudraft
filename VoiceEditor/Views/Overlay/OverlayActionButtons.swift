import AppKit
import SwiftUI

/// Action buttons for the Done / Speaking states: Copy, and a Read Aloud ↔ Stop toggle.
/// While TTS is playing (`isSpeaking`), the speaker button becomes a Stop button so the
/// user can silence playback without dismissing the overlay.
struct OverlayActionButtons: View {
    let text: String
    let theme: DictationTheme
    let isSpeaking: Bool
    let onReadAloud: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            OverlayIconButton(icon: "doc.on.doc", tooltip: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if isSpeaking {
                OverlayIconButton(icon: "stop.fill", tooltip: "Stop") {
                    onStop()
                }
            } else {
                OverlayIconButton(icon: "speaker.wave.2", tooltip: "Read Aloud") {
                    onReadAloud()
                }
            }
        }
    }
}

/// A small icon button with hover effect for the overlay pill.
struct OverlayIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }
}
