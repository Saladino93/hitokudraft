import SwiftUI

/// Speaking state: play icon + sentence-level TTS highlighting + progress bar.
struct SpeakingIndicator: View {
    let theme: DictationTheme

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 12))
            .foregroundColor(theme.speakingAccentColor)
            .frame(width: 25, height: 16)
    }
}

/// Text with sentence-level TTS highlighting.
/// Current sentence is bright; others are dimmed.
struct SpeakingTextView: View {
    let fullText: String
    let currentSentence: String
    let theme: DictationTheme
    let maxLines: Int

    var body: some View {
        if currentSentence.isEmpty || !fullText.contains(currentSentence) {
            Text(fullText)
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(maxLines)
        } else if let range = fullText.range(of: currentSentence) {
            let before = String(fullText[fullText.startIndex..<range.lowerBound])
            let current = String(fullText[range])
            let after = String(fullText[range.upperBound..<fullText.endIndex])

            (Text(before).foregroundColor(.white.opacity(0.28))
             + Text(current).foregroundColor(.white.opacity(0.90)).fontWeight(.medium)
             + Text(after).foregroundColor(.white.opacity(0.28)))
                .font(.system(size: 15))
                .lineLimit(maxLines)
                .animation(.easeInOut(duration: 0.3), value: currentSentence)
        }
    }
}

/// Progress bar for TTS playback.
struct SpeakingProgressBar: View {
    let progress: Double
    let theme: DictationTheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.speakingAccentColor)
                    .frame(width: geo.size.width * max(0, min(progress, 1.0)), height: 3)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 3)
    }
}
