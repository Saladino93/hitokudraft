import SwiftUI

/// Done state indicator: circle with checkmark.
struct DoneIndicator: View {
    var body: some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: 14, weight: .light))
            .foregroundColor(.white.opacity(0.35))
            .frame(width: 25, height: 16)
    }
}
