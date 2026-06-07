import SwiftUI

/// "How to use" help tab. Plain descriptions, no scrolling and no shortcut badges
/// (the shortcuts live in the General tab).
struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpRow(
                icon: "mic.fill",
                title: "Dictate",
                text: "Press to start, then press again or just stop talking to finish. Your speech is typed wherever your cursor is."
            )
            helpRow(
                icon: "wand.and.stars",
                title: "Edit or ask with voice",
                text: "With text selected, say how to change it, for example \"make it formal\". With nothing selected, ask a question, for example \"explain this\". Press again to stop. If your cursor is in a text field the result is pasted, otherwise it appears in the overlay."
            )
            helpRow(
                icon: "hammer.fill",
                title: "Tool use",
                text: "Speak a request that needs an action, such as creating a calendar event or searching the web. The assistant runs the matching tool and shows the result."
            )
            helpRow(
                icon: "waveform",
                title: "Transcribe files",
                text: "Open the menu bar icon and choose Transcribe File. Drop in one or more audio or video files, get clean text, then refine it with your voice."
            )
            helpRow(
                icon: "eye",
                title: "Screen awareness (Beta)",
                text: "When enabled in the General tab, the assistant can read what is on your screen for more relevant answers. It works best for translating or summarizing visible text. Results can vary."
            )
            helpRow(
                icon: "cpu",
                title: "Models",
                text: "The speech model controls how the app hears you. The AI model handles editing and answers. Gemma 4 can do both, hearing and seeing."
            )
            helpRow(
                icon: "lock.fill",
                title: "Privacy",
                text: "Everything runs on your Mac. Your audio and text never leave your device."
            )

            Spacer(minLength: 8)

            Text(L("model.ai_warning"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.yellow)
                .frame(maxWidth: .infinity, alignment: .center)
                // Sit roughly 10% up from the bottom rather than flush against it.
                .padding(.bottom, 40)
        }
        .padding(20)
        // Push the first row (Dictate) down ~5% now that the heading is gone.
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func helpRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
