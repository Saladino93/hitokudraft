import AppKit
import ApplicationServices
import PDFKit
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
    /// `documentBudget` > 0 enables PDF/Pages/Word document extraction in Advanced mode
    /// (budget is in characters; scales with model capability via `ModelOption.documentContextBudget`).
    func capture(mode: ContextAwareMode, documentBudget: Int = 0) async -> ScreenContext {
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

        // Advanced mode: always run OCR on focused app for broader page context.
        // Task.detached keeps VNImageRequestHandler.perform off the main actor — it is a
        // synchronous blocking call (50–500 ms) and nonisolated alone does not prevent it
        // from running on the main thread when called from @MainActor context.
        if let image = await captureWindow(pid: pid) {
            let ocrText = await Task.detached(priority: .userInitiated) {
                self.runOCR(on: image)
            }.value
            if let ocrText, !ocrText.isEmpty {
                if ctx.focusedText == nil {
                    ctx.focusedText = String(ocrText.prefix(2000))
                }
                if ctx.source == .none { ctx.source = .ocr }
            }
        }
        if ctx.source == .none { ctx.source = .titleOnly }

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

            if let bgImage = await captureWindow(pid: bgPid) {
                let bgOCR = await Task.detached(priority: .userInitiated) {
                    self.runOCR(on: bgImage)
                }.value
                if let bgOCR, !bgOCR.isEmpty {
                    ctx.backgroundText = String(bgOCR.prefix(2000))
                }
            }
        }

        // Advanced mode: broader document context (PDF pages, Pages/Word body).
        // Runs only when caller provides a non-zero budget (i.e. an LLM is loaded).
        // Scanned PDFs return nil here and fall back to the OCR already captured above.
        if documentBudget > 0 {
            ctx.documentContext = await captureDocumentContext(
                app: app, pid: pid,
                budget: documentBudget,
                selectedText: ctx.selectedText
            )
        }

        return ctx
    }

    // MARK: - Document Context (PDFKit + AppleScript)

    /// Dispatches to the appropriate document extractor based on the frontmost app.
    /// PDF: AX window document path → PDFKit text layer (anchored to selected-text page).
    /// Pages / Word: AppleScript body text.
    /// Returns nil when unsupported, when the PDF has no text layer, or on any error.
    private func captureDocumentContext(
        app: NSRunningApplication,
        pid: pid_t,
        budget: Int,
        selectedText: String?
    ) async -> String? {
        let bundleID = app.bundleIdentifier ?? ""

        if bundleID == "com.apple.iWork.Pages" {
            return await Task.detached(priority: .userInitiated) {
                Self.runAppleScript(
                    """
                    tell application "Pages"
                        if (count of documents) > 0 then
                            return body text of front document
                        end if
                    end tell
                    """,
                    budget: budget
                )
            }.value
        }

        if bundleID == "com.microsoft.Word" {
            return await Task.detached(priority: .userInitiated) {
                Self.runAppleScript(
                    """
                    tell application "Microsoft Word"
                        if (count of documents) > 0 then
                            return content of text object of active document
                        end if
                    end tell
                    """,
                    budget: budget
                )
            }.value
        }

        // PDF: any app that exposes a .pdf via kAXDocumentAttribute (Preview, PDF Expert, Skim, …)
        guard let docURL = axDocumentURL(pid: pid),
              docURL.pathExtension.lowercased() == "pdf" else { return nil }
        let sel = selectedText
        return await Task.detached(priority: .userInitiated) {
            Self.extractPDFText(at: docURL, selectedText: sel, budget: budget)
        }.value
    }

    /// Reads `kAXDocumentAttribute` from the focused window and returns it as a file URL.
    private func axDocumentURL(pid: pid_t) -> URL? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }
        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXDocumentAttribute as CFString, &docRef
        ) == .success, let docString = docRef as? String else { return nil }
        // kAXDocumentAttribute returns a file:// URL string
        return URL(string: docString) ?? URL(fileURLWithPath: docString)
    }

    /// Extracts text from a PDF using PDFKit, anchored to the page that contains `selectedText`.
    /// Math symbols and code are preserved as Unicode characters from the text layer.
    /// Returns nil for scanned image-only PDFs (no text layer) — OCR is the fallback for those.
    nonisolated private static func extractPDFText(
        at url: URL,
        selectedText: String?,
        budget: Int
    ) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return nil }

        // Anchor to the page that contains the selected text (fast PDFKit search).
        // Falls back to page 0 when there is no selection or the text is not found.
        // Skip anchor search for large PDFs (>50 pages): findString scans the entire
        // document sequentially and can take seconds on a 500–1000 page textbook.
        var anchorIdx = 0
        if let sel = selectedText, sel.count > 10, pageCount <= 50 {
            let query = String(sel.prefix(50))
            if let hit = doc.findString(query, withOptions: .caseInsensitive).first,
               let hitPage = hit.pages.first {
                anchorIdx = doc.index(for: hitPage)
            }
        }

        // Expand outward from anchor: anchor, anchor−1, anchor+1, anchor−2, anchor+2, …
        var result = ""
        for pageIdx in Self.pageSequence(anchor: anchorIdx, total: pageCount) {
            guard let page = doc.page(at: pageIdx),
                  let text = page.string, !text.isEmpty else { continue }
            let remaining = budget - result.count
            guard remaining > 100 else { break }
            if !result.isEmpty { result += "\n\n[p.\(pageIdx + 1)]\n" }
            result += String(text.prefix(remaining))
        }
        return result.isEmpty ? nil : result
    }

    /// Returns page indices starting at `anchor` and expanding outward, capped at 5 pages.
    nonisolated private static func pageSequence(anchor: Int, total: Int) -> [Int] {
        var pages = [anchor]
        for delta in 1..<total {
            if pages.count >= 5 { break }
            let before = anchor - delta
            let after  = anchor + delta
            if before >= 0    { pages.append(before) }
            if after < total  { pages.append(after) }
        }
        return pages
    }

    /// Executes a simple AppleScript and returns the string result trimmed to `budget` chars.
    nonisolated private static func runAppleScript(_ source: String, budget: Int) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue, !text.isEmpty else { return nil }
        return String(text.prefix(budget))
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
