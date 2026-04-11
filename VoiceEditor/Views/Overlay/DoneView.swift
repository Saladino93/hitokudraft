import SwiftUI

/// Done state indicator: circle with checkmark.
struct DoneIndicator: View {
    var body: some View {
        // Invisible spacer — no indicator for done state, keeps layout consistent
        Color.clear.frame(width: 25, height: 16)
    }
}
