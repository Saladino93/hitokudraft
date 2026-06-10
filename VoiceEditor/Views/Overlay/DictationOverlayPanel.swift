import AppKit
import SwiftUI

/// Bridging context for the CGEventTap C callback → @MainActor coordinator.
private final class EscapeTapContext: @unchecked Sendable {
    weak var coordinator: ConversationCoordinator?
    var tap: CFMachPort?
}

/// A borderless `NSPanel` reports `canBecomeKey == false`, which blocks
/// scrolling and text selection in the SwiftUI content (button clicks still
/// work because mouse-down reaches non-key windows). Overriding `canBecomeKey`
/// restores interaction. Because the panel is also `.nonactivatingPanel`,
/// taking key status does NOT activate our app or deactivate the user's
/// frontmost app — so dictation can still paste into that app.
final class InteractiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A floating, non-activating panel that shows the overlay pill.
/// Manages NSPanel lifecycle, Esc key interception, and show/hide transitions.
/// The SwiftUI content is driven entirely by `OverlayViewModel`.
@MainActor
final class DictationOverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private weak var coordinator: ConversationCoordinator?

    /// The screen the overlay was first shown on — stays anchored here.
    private var anchoredScreen: NSScreen?

    /// Screen captured at hotkey-press time — used instead of NSScreen.main
    /// (which can shift during async setup before the overlay appears).
    var targetScreen: NSScreen?

    // Esc key tap state
    private var escapeTapInstalled = false
    private var escapeTapContext: EscapeTapContext?
    private var escapeTap: CFMachPort?
    private var escapeTapSource: CFRunLoopSource?
    private var escapeMonitorFallback: Any?

    // MARK: - Public API (same interface as old monolith)

    /// Subscribe to coordinator observable properties. Called once from coordinator's init.
    func observe(_ coordinator: ConversationCoordinator) {
        self.coordinator = coordinator

        // Single hook for all overlay state changes: show/hide panel + Esc tap.
        // (Callback instead of observation tracking — the panel needs every state
        // assignment, and the didSet hook delivers them synchronously in order.)
        viewModel.onOverlayStateChange = { [weak self] state in
            guard let self else { return }
            if let state {
                self.showPanel(for: state)
                // Install Esc tap for display mode (Done/Speaking)
                if case .done = state, !self.escapeTapInstalled {
                    self.installEscapeTap()
                } else if case .speaking = state, !self.escapeTapInstalled {
                    self.installEscapeTap()
                }
            } else {
                self.hide()
            }
        }

        viewModel.observe(coordinator)
    }

    // MARK: - Panel Lifecycle

    private var lastPanelLines = 0

    private func showPanel(for state: OverlayState) {
        let lines = linesNeeded(for: state)
        let bottomBar = state.hasBottomBar
        if panel == nil {
            // Use screen captured at hotkey time; fall back to NSScreen.main
            anchoredScreen = targetScreen ?? NSScreen.main
            targetScreen = nil
            lastPanelLines = lines
            createPanel(forLines: lines, hasBottomBar: bottomBar)
        } else if lines != lastPanelLines {
            // Only resize when line count actually changes (prevents bouncing during streaming)
            lastPanelLines = lines
            resizePanel(forLines: lines, hasBottomBar: bottomBar)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        viewModel.stopPolling()
        removeEscapeTap()
        panel?.orderOut(nil)
        panel = nil
        anchoredScreen = nil
        lastPanelLines = 0
    }

    private func createPanel(forLines lines: Int, hasBottomBar: Bool = false) {
        let width = panelWidth
        let height = panelHeight(forLines: lines, hasBottomBar: hasBottomBar)

        let panel = InteractiveOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
        // Needed for SwiftUI `.onHover` tracking to fire on a non-active panel.
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = anchoredScreen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - width / 2,
                y: frame.maxY - height
            ))
        }

        let hostingView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        self.panel = panel
    }

    private func linesNeeded(for state: OverlayState) -> Int {
        switch state {
        case .listening: return max(2, UserDefaults.standard.integer(forKey: "overlayLineCount"))
        case .generating: return max(3, viewModel.displayModeMaxLines)
        case .speaking, .done: return viewModel.displayModeMaxLines
        }
    }

    private func resizePanel(forLines lines: Int, hasBottomBar: Bool = false) {
        guard let panel, let screen = anchoredScreen ?? NSScreen.main else { return }
        let width = panelWidth
        let height = panelHeight(forLines: lines, hasBottomBar: hasBottomBar)
        let screenFrame = screen.visibleFrame
        let newFrame = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
        guard newFrame != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Sizing

    private var overlayWidthSetting: CGFloat {
        let raw = UserDefaults.standard.double(forKey: "overlayWidth")
        return CGFloat(raw > 0 ? max(150, min(raw, 500)) : 350)
    }

    private var panelWidth: CGFloat { overlayWidthSetting + 16 }

    private func panelHeight(forLines lines: Int, hasBottomBar: Bool = false) -> CGFloat {
        let capsuleHeight: CGFloat = 35 + CGFloat(max(0, lines - 1)) * 20
        return capsuleHeight + (hasBottomBar ? 40 : 8)
    }

    // MARK: - Esc Key Tap

    private func installEscapeTap() {
        escapeTapInstalled = true
        let ctx = EscapeTapContext()
        ctx.coordinator = coordinator
        self.escapeTapContext = ctx
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let userInfo {
                        let c = Unmanaged<EscapeTapContext>.fromOpaque(userInfo).takeUnretainedValue()
                        if let t = c.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      event.getIntegerValueField(.keyboardEventKeycode) == 53,
                      let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let c = Unmanaged<EscapeTapContext>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in c.coordinator?.clearDisplayModeResult() }
                return nil
            },
            userInfo: ctxPtr
        ) else {
            escapeMonitorFallback = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor [weak self] in
                    self?.coordinator?.clearDisplayModeResult()
                }
            }
            return
        }

        ctx.tap = tap
        self.escapeTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.escapeTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEscapeTap() {
        if let tap = escapeTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = escapeTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        escapeTap = nil
        escapeTapSource = nil
        escapeTapContext = nil
        if let monitor = escapeMonitorFallback {
            NSEvent.removeMonitor(monitor)
            escapeMonitorFallback = nil
        }
        escapeTapInstalled = false
    }
}
