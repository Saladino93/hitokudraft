import AppKit
import SwiftMath
import SwiftUI

/// SwiftUI wrapper around SwiftMath's `MTMathUILabel` for rendering LaTeX math on macOS.
///
/// Future LaTeX backends (e.g. a web-based KaTeX renderer) can replace this file without
/// touching any other code — `OverlayTextRenderer` only references `MathView` by name.
///
/// Usage:
///   MathView(latex: "G_{\\mu\\nu} + \\Lambda g_{\\mu\\nu} = \\frac{8\\pi G}{c^4} T_{\\mu\\nu}")
struct MathView: NSViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 14
    var textColor: NSColor = NSColor.white.withAlphaComponent(0.92)
    /// `.display` for standalone equations; `.text` for inline fragments.
    var labelMode: MTMathUILabelMode = .display

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = labelMode
        label.textAlignment = .left
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = textColor
        label.labelMode = labelMode
    }

    /// Reports the natural rendered size of the math expression.
    /// SwiftUI uses this to allocate the correct height in the VStack — crucial for
    /// tall formulas with fractions or stacked scripts.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView label: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        let natural = label.fittingSize
        let proposedWidth = proposal.width ?? natural.width
        // Take at most the available width; always use the formula's natural height.
        return CGSize(
            width: max(1, min(proposedWidth, natural.width)),
            height: max(1, natural.height)
        )
    }
}

// MARK: - Inline image rendering

extension MathView {
    /// Renders a LaTeX expression to an `NSImage` using `.text` label mode (inline-sized).
    /// Used by `OverlayTextRenderer` to build inline `Text + Text(Image(...))` layouts.
    /// Results are cached by expression so SwiftUI view updates don't re-render on every pass.
    /// `@MainActor` — MTMathUILabel is an NSView subclass and must be touched on the main thread.
    @MainActor
    static func renderToImage(
        latex: String,
        fontSize: CGFloat = 14,
        color: NSColor = NSColor.white.withAlphaComponent(0.92)
    ) -> NSImage? {
        let cacheKey = "\(fontSize)|\(color)|\(latex)"
        if let cached = imageCache[cacheKey] { return cached }

        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = .text  // inline-sized; .display adds extra vertical spacing

        let size = label.fittingSize
        guard size.width > 1, size.height > 1 else { return nil }
        label.frame = NSRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        // Off-screen rendering: works without the view being in a window hierarchy
        // because MTMathUILabel.draw(_:) uses CoreText directly.
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)

        // Evict cache when it grows large (each image is small, but keep it bounded).
        if imageCache.count >= 200 { imageCache.removeAll() }
        imageCache[cacheKey] = image
        return image
    }

    // Internal cache — static so it survives SwiftUI view struct recreation.
    // @MainActor isolation matches renderToImage; no concurrent access possible.
    @MainActor private static var imageCache: [String: NSImage] = [:]
}
