import SwiftUI

struct DownloadProgressView: View {
    let progress: Double
    let statusMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress >= 1.0 {
                // STT loading phase — no granular progress, show indeterminate spinner
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage.isEmpty ? "Loading..." : statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: progress) {
                    Text(statusMessage.isEmpty ? "Downloading..." : statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
