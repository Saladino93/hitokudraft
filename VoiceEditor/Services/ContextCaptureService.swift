import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import os

/// Captures screen context (app name, window title, selected/visible text) from the
/// last active external application, using Accessibility APIs and optional OCR fallback.
@MainActor
final class ContextCaptureService {
    private static let log = Logger(subsystem: "com.hitokudraft.context", category: "capture")

    /// Most recent external apps (index 0 = most recent, max 2).
    private(set) var recentExternalApps: [NSRunningApplication] = []
    private var observer: Any?

    /// The last focused external app (convenience).
    var lastExternalApp: NSRunningApplication? { recentExternalApps.first }

    init() {
        if let app = NSWorkspace.shared.frontmostApplication {
            recentExternalApps = [app]
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor in self?.pushApp(app) }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Push a newly-activated app to front of the recents list, deduplicating by bundle ID.
    private func pushApp(_ app: NSRunningApplication) {
        recentExternalApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        recentExternalApps.insert(app, at: 0)
        if recentExternalApps.count > 2 {
            recentExternalApps = Array(recentExternalApps.prefix(2))
        }
    }

    /// Capture screen context using the specified mode.
    func capture(mode: ContextAwareMode) async -> ScreenContext {
        guard mode != .off else { return ScreenContext() }
        guard let app = lastExternalApp else { return ScreenContext() }

        var ctx = ScreenContext(appName: app.localizedName)
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Window title
        if let windowRef = axValue(appElement, kAXFocusedWindowAttribute) {
            let window = unsafeBitCast(windowRef, to: AXUIElement.self)
            ctx.windowTitle = axValue(window, kAXTitleAttribute) as? String
        }

        // Try Accessibility: selected text → focused element value
        if let focusedRef = axValue(appElement, kAXFocusedUIElementAttribute) {
            let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
            if let sel = axValue(focused, kAXSelectedTextAttribute) as? String, !sel.isEmpty {
                ctx.selectedText = String(sel.prefix(2000))
                ctx.source = .accessibility
            } else if let val = axValue(focused, kAXValueAttribute) as? String, !val.isEmpty {
                ctx.focusedText = String(val.prefix(2000))
                ctx.source = .accessibility
            }
        }

        // Standard mode: done after Accessibility (return what we have)
        if mode == .standard {
            if ctx.source == .none { ctx.source = .titleOnly }
            return ctx
        }

        // Advanced mode: always run OCR on focused app for broader page context
        if let image = await captureWindow(pid: pid),
           let ocrText = runOCR(on: image), !ocrText.isEmpty {
            if ctx.focusedText == nil {
                ctx.focusedText = String(ocrText.prefix(2000))
            }
            if ctx.source == .none { ctx.source = .ocr }
        } else if ctx.source == .none {
            ctx.source = .titleOnly
        }

        // Advanced mode: also capture background app via OCR
        if recentExternalApps.count > 1 {
            let bgApp = recentExternalApps[1]
            ctx.backgroundAppName = bgApp.localizedName

            let bgPid = bgApp.processIdentifier
            let bgElement = AXUIElementCreateApplication(bgPid)
            if let bgWindowRef = axValue(bgElement, kAXFocusedWindowAttribute) {
                let bgWindow = unsafeBitCast(bgWindowRef, to: AXUIElement.self)
                ctx.backgroundWindowTitle = axValue(bgWindow, kAXTitleAttribute) as? String
            }

            if let bgImage = await captureWindow(pid: bgPid),
               let bgOCR = runOCR(on: bgImage), !bgOCR.isEmpty {
                ctx.backgroundText = String(bgOCR.prefix(2000))
            }
        }

        return ctx
    }

    // MARK: - Window Capture

    private func captureWindow(pid: pid_t) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            let targetID = frontmostWindowID(for: pid)
            let window: SCWindow?
            if let targetID {
                window = content.windows.first { $0.windowID == targetID }
            } else {
                window = content.windows.first {
                    $0.owningApplication?.processID == pid && $0.isOnScreen
                }
            }

            guard let window else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = min(Int(window.frame.width) * 2, 3840)
            config.height = min(Int(window.frame.height) * 2, 2160)
            config.capturesAudio = false
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            Self.log.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func frontmostWindowID(for pid: pid_t) -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0
            else { continue }
            return windowID
        }
        return nil
    }

    // MARK: - OCR

    private nonisolated func runOCR(on image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else { return nil }
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - Accessibility Helpers

    private nonisolated func axValue(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
            ? value : nil
    }
}
