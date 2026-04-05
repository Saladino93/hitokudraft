import AppKit
import Combine
import SwiftUI


/// A floating, non-activating panel that shows live dictation text
/// with an animated waveform visualization driven by real-time audio level.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private var cancellables = Set<AnyCancellable>()
    private weak var coordinator: ConversationCoordinator?
    /// Non-nil means a monitor install was attempted (even if system returned nil due to permissions).
    /// Using a separate Bool prevents repeated install attempts when Accessibility is denied.
    private var escapeMonitorInstalled: Bool = false
    private var escapeMonitor: Any?

    private var theme: DictationTheme { .current }

    func show(text: String, isStatus: Bool = false) {
        viewModel.text = text
        viewModel.isStatus = isStatus
        viewModel.showText = (UserDefaults.standard.object(forKey: "showDictationText") as? Bool) ?? true

        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    /// Start polling audio level from a ContinuousSession at ~30fps.
    func startLevelPolling(session: AudioCaptureService.ContinuousSession) {
        viewModel.startPolling(session: session)
    }

    func stopLevelPolling() {
        viewModel.stopPolling()
    }

    func hide() {
        stopLevelPolling()
        viewModel.isStreamingLLM = false
        viewModel.isDisplayMode = false
        viewModel.displayModeMaxLines = 3
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        escapeMonitorInstalled = false
        panel?.orderOut(nil)
        panel = nil
    }

    /// Subscribe to coordinator published properties so the overlay reacts
    /// to state changes without being commanded directly.
    func observe(_ coordinator: ConversationCoordinator) {
        self.coordinator = coordinator

        // Show/hide and set text based on pipeline state.
        // Capture coordinator weakly so we can read displayModeResult directly —
        // that value is already synchronously set before state transitions to .idle,
        // so checking it here avoids any Combine sink ordering race.
        coordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self, weak coordinator] state in
                guard let self else { return }
                switch state {
                case .listening:
                    self.show(text: L("overlay.listening"), isStatus: true)
                case .transcribing:
                    // Only update if panel is already open (voice edit opened it at .listening).
                    // Grammar fix never opens the panel, so it must stay hidden here.
                    if self.panel != nil { self.show(text: L("overlay.transcribing"), isStatus: true) }
                case .generating:
                    if self.panel != nil { self.show(text: L("overlay.generating"), isStatus: true) }
                case .pasting:
                    if self.panel != nil { self.show(text: L("overlay.pasting"), isStatus: true) }
                case .dictating(let text):
                    self.show(text: text.isEmpty ? L("overlay.dictating") : text,
                              isStatus: text.isEmpty)
                case .idle, .error, .downloading, .warmingUp:
                    // Don't close while showing a display-mode result.
                    // Read displayModeResult directly — it's already set before state = .idle,
                    // so this is never stale regardless of sink delivery order.
                    let inDisplayMode = !(coordinator?.displayModeResult.isEmpty ?? true)
                    if !inDisplayMode { self.hide() }
                }
            }
            .store(in: &cancellables)

        // Live transcription text during voice recording
        coordinator.$liveTranscriptionText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, !text.isEmpty else { return }
                self.show(text: text, isStatus: false)
            }
            .store(in: &cancellables)

        // Streaming LLM tokens — only updates an already-open panel (voice edit).
        // Grammar fix never opens the panel so panel == nil there; this is a no-op.
        // Forces 3-line mode via isStreamingLLM flag for the duration of generation.
        // Gated by the "showLLMStreamingInOverlay" user setting (default: on).
        coordinator.$streamingLLMText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.panel != nil else { return }
                let streamingEnabled = (UserDefaults.standard.object(forKey: "showLLMStreamingInOverlay") as? Bool) ?? true
                if text.isEmpty {
                    self.viewModel.isStreamingLLM = false
                } else if streamingEnabled {
                    self.viewModel.isStreamingLLM = true
                    self.show(text: text, isStatus: false)
                }
            }
            .store(in: &cancellables)

        // Display-mode result — shown when the focused element is not editable.
        // Resizes the panel to fit the text (up to displayModeMaxLines lines).
        // Auto-hides when coordinator clears the result; Esc key also dismisses.
        coordinator.$displayModeResult
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if text.isEmpty {
                    self.hide()
                } else {
                    let lines = self.calculateLinesNeeded(for: text)
                    self.viewModel.displayModeMaxLines = lines
                    self.viewModel.isStreamingLLM = true  // keeps 3-line+ mode
                    self.viewModel.isDisplayMode = true
                    self.show(text: text, isStatus: false)
                    self.resizePanel(forLines: lines)
                    // Global Esc monitor — dismisses overlay from any app.
                    // Guard with escapeMonitorInstalled (not escapeMonitor == nil) so that a nil
                    // return from addGlobalMonitorForEvents (Accessibility denied) doesn't cause
                    // repeated install attempts on every displayModeResult update.
                    if !self.escapeMonitorInstalled {
                        self.escapeMonitorInstalled = true
                        self.escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                            guard event.keyCode == 53 else { return }  // 53 = Esc
                            Task { @MainActor [weak self] in
                                self?.coordinator?.clearDisplayModeResult()
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Waveform level polling — follows the active recording session
        coordinator.$activeRecordingSession
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                if let session {
                    self.startLevelPolling(session: session)
                } else {
                    self.stopLevelPolling()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Display-mode helpers

    /// Maximum line count the overlay will expand to in display mode.
    private static let displayModeMaxLines = 10

    /// Rounded medium 14pt — matches DictationOverlayContent's overlayFont.
    private static let displayModeFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 14, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 14) } ?? base
    }()

    /// Returns the number of lines `text` needs at the current overlay width, capped at displayModeMaxLines.
    /// Falls back to 3 on any measurement error.
    private func calculateLinesNeeded(for text: String) -> Int {
        let overlayWidth = CGFloat(
            UserDefaults.standard.double(forKey: "overlayWidth")
                .clamped(to: 150...400, default: 210)
        )
        let textAreaWidth = max(1, overlayWidth - 65)  // same deduction as DictationOverlayContent
        let font = Self.displayModeFont
        let lineHeight = font.ascender - font.descender + font.leading
        guard lineHeight > 0 else { return 3 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: textAreaWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil
        )
        let needed = max(3, Int(ceil(rect.height / lineHeight)))
        return min(needed, Self.displayModeMaxLines)
    }

    /// Resizes the overlay panel to accommodate `lineCount` lines, with animation.
    /// No-op if the panel is already the correct size or doesn't exist.
    private func resizePanel(forLines lineCount: Int) {
        guard let panel, let screen = NSScreen.main else { return }
        let overlayWidth = CGFloat(
            UserDefaults.standard.double(forKey: "overlayWidth")
                .clamped(to: 150...400, default: 210)
        )
        let panelWidth = overlayWidth + 16
        let maxCapsuleHeight = 35 + CGFloat(lineCount - 1) * 18
        let panelHeight = maxCapsuleHeight + 33
        let screenFrame = screen.visibleFrame
        let newFrame = NSRect(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )
        guard newFrame != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func createPanel() {
        // Read user-configurable overlay dimensions
        let capsuleWidth = CGFloat(UserDefaults.standard.double(forKey: "overlayWidth").clamped(to: 150...400, default: 210))

        // Size the panel to match the current displayModeMaxLines so that
        // display-mode results create a panel at the right height immediately.
        // For normal dictation (maxLines = 3) this produces the same 3-line panel as before.
        let maxCapsuleHeight: CGFloat = 35 + CGFloat(max(0, viewModel.displayModeMaxLines - 1)) * 18
        let panelWidth: CGFloat = capsuleWidth + 16
        let panelHeight: CGFloat = maxCapsuleHeight + 33

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panelWidth / 2
            let y = frame.maxY - panelHeight
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel, theme: theme)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: content.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
        self.panel = panel
    }
}


// MARK: - ViewModel


@MainActor
private final class OverlayViewModel: ObservableObject {
    @Published var text: String = "Dictating..."
    @Published var audioLevel: CGFloat = 0
    @Published var showText: Bool = (UserDefaults.standard.object(forKey: "showDictationText") as? Bool) ?? true
    @Published var isStatus: Bool = false
    @Published var isStreamingLLM: Bool = false
    @Published var isDisplayMode: Bool = false
    @Published var displayModeMaxLines: Int = 3  // increased when showing long display-mode results
    @Published var tick = Date()

    private var displayLink: CVDisplayLink?
    private weak var session: AudioCaptureService.ContinuousSession?
    private var timer: Timer?

    func startPolling(session: AudioCaptureService.ContinuousSession) {
        self.session = session
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollLevel()
            self.tick = Date()
        }
        t.tolerance = (1.0 / 30.0) * 0.1  // 10% slack for timer coalescing
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        session = nil
        audioLevel = 0
    }

    private func pollLevel() {
        guard let session else {
            audioLevel = 0
            return
        }
        let raw = CGFloat(session.audioLevel)
        let normalized = min(raw / 0.15, 1.0)
        audioLevel = normalized
    }
}


// MARK: - Overlay View


private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: OverlayViewModel
    var theme: DictationTheme

    @AppStorage("overlayWidth") private var overlayWidth: Double = 210
    @AppStorage("overlayLineCount") private var overlayLineCount: Int = 2

    /// Show text only when the setting is on AND this isn't a bare status message.
    private var effectiveShowText: Bool {
        viewModel.showText && !viewModel.isStatus
    }

    /// During LLM streaming / display mode: use displayModeMaxLines (3–10).
    /// During dictation/transcription: respect the user's setting.
    private var maxLines: Int {
        viewModel.isStreamingLLM ? viewModel.displayModeMaxLines : max(1, min(3, overlayLineCount))
    }

    private var capsuleWidth: CGFloat {
        CGFloat(overlayWidth).clamped(to: 150...400)
    }

    /// Font matching the SwiftUI display font, used for line-count measurement.
    private static let overlayFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 14, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 14) } ?? base
    }()

    /// Available width for text inside the capsule.
    private var textAreaWidth: CGFloat {
        capsuleWidth - 65  // 14*2 padding + 8 spacing + 29 waveform
    }

    // Cached values — recomputed only when text changes (not on 30fps waveform ticks).
    @State private var cachedLineCount: Int = 1
    @State private var cachedTailText: String = ""

    private func recompute() {
        guard effectiveShowText, !viewModel.text.isEmpty else {
            cachedLineCount = 1
            cachedTailText = viewModel.text
            return
        }
        let font = Self.overlayFont
        let width = max(1, textAreaWidth)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = font.ascender - font.descender + font.leading
        let rect = (viewModel.text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil
        )
        let needed = max(1, Int(ceil(rect.height / lineHeight)))
        cachedLineCount = min(needed, maxLines)

        cachedTailText = viewModel.text
    }

    private var capsuleHeight: CGFloat {
        35 + CGFloat(cachedLineCount - 1) * 18
    }

    /// Height for the text scroll area (2–3 line modes), aligned to exact line boundaries.
    private var textAreaHeight: CGFloat {
        let font = Self.overlayFont
        let lineHeight = font.ascender - font.descender + font.leading
        return lineHeight * CGFloat(cachedLineCount)
    }

    var body: some View {
        HStack(spacing: 8) {
            WaveformBarsView(level: viewModel.audioLevel, date: viewModel.tick, theme: theme)
                .frame(width: 29, height: 16)

            if effectiveShowText {
                OverlayTextRenderer(
                    text: viewModel.text,
                    maxLines: maxLines,
                    textAreaHeight: textAreaHeight
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: effectiveShowText ? capsuleWidth : 64, height: capsuleHeight)
        .background {
            // Fixed 17.5 pt radius matches the pill shape at 35 pt height (normal mode)
            // but doesn't distort into an oval for tall display-mode content.
            RoundedRectangle(cornerRadius: 17.5, style: .continuous)
                .fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 17.5, style: .continuous)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            // Copy button — only in display mode. Cmd+C doesn't reach a non-activating panel
            // (key events go to the active app), so this button is the reliable copy path.
            if viewModel.isDisplayMode {
                CopyButton(text: viewModel.text)
                    .padding(.bottom, 7)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { recompute() }
        .onChange(of: viewModel.text) { recompute() }
        .onChange(of: viewModel.isStatus) { recompute() }
        .onChange(of: viewModel.isStreamingLLM) { recompute() }
        .onChange(of: viewModel.displayModeMaxLines) { recompute() }
        .animation(.easeInOut(duration: 0.2), value: effectiveShowText)
        .animation(.easeInOut(duration: 0.15), value: cachedLineCount)
        .animation(.spring(duration: 0.25), value: viewModel.isStreamingLLM)
    }
}


// MARK: - Text Segment
// TextSegment enum and parseSegments(_:) are defined in OverlaySegmentParser.swift
// so they can be unit-tested without importing AppKit/SwiftUI.


// MARK: - Overlay Text Renderer
//
// Extension points:
//   LaTeX backend  → MathView.swift only (renderToImage API)
//   Code highlight → CodeHighlighter.swift only (highlight(code:language:) API)
// Neither this struct nor any callers change when swapping either backend.


private struct OverlayTextRenderer: View {
    let text: String
    let maxLines: Int
    let textAreaHeight: CGFloat

    private var segments: [TextSegment] { parseSegments(text) }

    /// True when any segment needs non-plain rendering (math, code block, inline code).
    private var hasComplexContent: Bool {
        segments.contains {
            if case .plain = $0 { return false }
            return true
        }
    }

    var body: some View {
        if !hasComplexContent {
            // Fast path: plain text only — existing behaviour unchanged.
            plainTextView
        } else if maxLines == 1 {
            // 1-line streaming mode: too narrow for code blocks; show plain text.
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            complexContentView
        }
    }

    // MARK: - Fast plain-text path (2–N lines, no math/code)

    @ViewBuilder
    private var plainTextView: some View {
        if maxLines == 1 {
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .frame(height: textAreaHeight)
                .clipped()
                .onChange(of: text) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Complex rendering path (math and/or code blocks)

    /// Groups consecutive plain/math/inlineCode segments so they can be composed into a
    /// single SwiftUI Text (preserving inline wrapping), while code blocks break the flow.
    private enum SegmentGroup {
        case inline([TextSegment])
        case codeBlock(language: String, code: String)
    }

    private var groupedSegments: [SegmentGroup] {
        var groups: [SegmentGroup] = []
        var accumInline: [TextSegment] = []
        for seg in segments {
            switch seg {
            case .plain, .math, .inlineCode:
                accumInline.append(seg)
            case .codeBlock(let lang, let code):
                if !accumInline.isEmpty { groups.append(.inline(accumInline)); accumInline = [] }
                groups.append(.codeBlock(language: lang, code: code))
            }
        }
        if !accumInline.isEmpty { groups.append(.inline(accumInline)) }
        return groups
    }

    @ViewBuilder
    private var complexContentView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(groupedSegments.enumerated()), id: \.offset) { _, group in
                        switch group {
                        case .inline(let segs):
                            buildInlineText(from: segs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .codeBlock(let lang, let code):
                            CodeBlockView(language: lang, code: code)
                        }
                    }
                }
                .id("complexBottom")
            }
            .frame(height: max(textAreaHeight, 44))
            .clipped()
            .onChange(of: text) { proxy.scrollTo("complexBottom", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Inline Text builder (plain + math + inline code → single Text)

    /// Composes consecutive plain / math / inlineCode segments into one SwiftUI `Text`,
    /// preserving natural inline wrapping between prose and math/code.
    private func buildInlineText(from segs: [TextSegment]) -> Text {
        segs.reduce(Text("")) { acc, seg in
            switch seg {
            case .plain(let s):
                return acc + Text(s)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

            case .math(let expr):
                if let rendered = MathView.renderToImage(
                    latex: expr, fontSize: 14,
                    color: NSColor.white.withAlphaComponent(0.92)
                ) {
                    // Apply -descent so the math image sits on the text baseline rather than
                    // floating above it (Image bottom = baseline, fittingSize includes descent).
                    return acc + Text(Image(nsImage: rendered.image))
                        .baselineOffset(-rendered.descent)
                } else {
                    return acc + Text(expr)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }

            case .inlineCode(let code):
                return acc + Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))

            case .codeBlock:
                return acc  // code blocks render as separate SegmentGroup views
            }
        }
    }

    // parseSegments(_:) lives in OverlaySegmentParser.swift (module-level, internal, testable).
}


// MARK: - Code Block View

/// Renders a syntax-highlighted code block with a dark inset background and horizontal scroll.
/// Coloring is provided by CodeHighlighter (pure Swift, no external deps).
private struct CodeBlockView: View {
    let language: String
    let code: String

    /// Highlighted NSAttributedString → AttributedString for SwiftUI Text.
    private var highlightedText: AttributedString? {
        let ns = CodeHighlighter.highlight(code: code, language: language)
        return try? AttributedString(ns, including: \.appKit)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if let attr = highlightedText {
                    Text(attr)
                } else {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}


// MARK: - Copy Button


/// A small clipboard icon that copies `text` to the pasteboard.
/// Shows a checkmark for 1.5 s after a successful copy.
/// Used in display mode because Cmd+C never reaches a non-activating NSPanel.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(copied ? 0.9 : 0.45))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: copied)
    }
}


// MARK: - Waveform Bars


private struct WaveformBarsView: View {
    let level: CGFloat
    let date: Date
    var theme: DictationTheme

    private static let barCount = 7
    private static let minHeight: CGFloat = 2.5
    private static let maxHeight: CGFloat = 14.0

    // Incommensurate frequencies ensure bars never synchronize
    private static let frequencies: [Double] = [2.8, 3.6, 4.2, 3.0, 4.5, 3.3, 2.5]
    // Staggered phase offsets per bar
    private static let phaseOffsets: [Double] = [0.0, 0.9, 1.7, 2.5, 3.4, 4.1, 5.0]
    // Different smoothing alphas create a "settling cascade" after speech stops
    private static let smoothingAlphas: [CGFloat] = [0.15, 0.20, 0.25, 0.22, 0.18, 0.23, 0.16]
    // Idle breathing frequency
    private static let breathFrequency: Double = 0.3

    @State private var smoothedHeights: [CGFloat] = Array(
        repeating: WaveformBarsView.minHeight, count: WaveformBarsView.barCount
    )

    var body: some View {
        HStack(spacing: 2.0) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(level > 0.05 ? theme.accent : theme.accent.opacity(0.3))
                    .shadow(color: theme.accent.opacity(level > 0.05 ? 0.6 : 0.15), radius: 4)
                    .frame(width: 2.0, height: smoothedHeights[i])
            }
        }
        .onChange(of: date) { _, newDate in
            updateHeights(at: newDate)
        }
    }

    private func updateHeights(at now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        var newHeights = smoothedHeights

        for i in 0..<Self.barCount {
            let target: CGFloat
            if level > 0.05 {
                // Sine oscillator modulated by audio level
                let sine = sin(2.0 * .pi * Self.frequencies[i] * t + Self.phaseOffsets[i])
                let oscillation = 0.5 + 0.5 * sine // normalize to 0…1
                target = Self.minHeight + (Self.maxHeight - Self.minHeight) * level * CGFloat(oscillation)
            } else {
                // Idle breathing: slow sine pulse keeps bars alive
                let breath = sin(2.0 * .pi * Self.breathFrequency * t + Self.phaseOffsets[i])
                let pulse = 0.5 + 0.5 * breath // normalize to 0…1
                target = Self.minHeight + 1.5 * CGFloat(pulse)
            }

            // Per-bar exponential smoothing
            let alpha = Self.smoothingAlphas[i]
            newHeights[i] = newHeights[i] + alpha * (target - newHeights[i])
        }

        smoothedHeights = newHeights
    }
}


// MARK: - Clamping Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>, default fallback: Double) -> Double {
        self == 0 ? fallback : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>, default fallback: Int) -> Int {
        self == 0 ? fallback : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
