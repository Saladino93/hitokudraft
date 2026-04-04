import Foundation

// MARK: - Codable types

/// One domain entry loaded from AppDomainConfig.json.
struct AppDomainCategory: Codable {
    let id: String            // stable key, e.g. "email"
    let hint: String          // short style tag injected into [Hint: …]
    let appPatterns: [String] // matched against active app name (lowercased)
    let titlePatterns: [String] // matched against window title when app is a browser
}

private struct AppDomainConfig: Codable {
    let version: Int
    let browsers: [String]
    let categories: [AppDomainCategory]
}

// MARK: - AppDomainHint

/// Detects the domain of the user's active app and returns a short style hint for the LLM.
///
/// All data is loaded from `AppDomainConfig.json` in the app bundle — add new apps or
/// categories there without touching Swift code.
enum AppDomainHint {

    // MARK: - Config loading (once, on first use)

    private static let config: AppDomainConfig? = {
        guard let url = Bundle.main.url(forResource: "AppDomainConfig", withExtension: "json") else {
            assertionFailure("AppDomainConfig.json not found in bundle — hints disabled")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppDomainConfig.self, from: data)
        } catch {
            assertionFailure("AppDomainConfig.json decode failed: \(error)")
            return nil
        }
    }()

    // MARK: - Detection

    /// Detect the matching category for the active app, or nil if no rule matches.
    static func detect(appName: String?, windowTitle: String?) -> AppDomainCategory? {
        guard let cfg = config,
              let app = appName?.lowercased() else { return nil }

        // Tier 1: native app name match (first match wins)
        for category in cfg.categories {
            if category.appPatterns.contains(where: { app.contains($0) }) {
                return category
            }
        }

        // Tier 2: if app is a known browser, inspect the window title
        let isBrowser = cfg.browsers.contains(where: { app.contains($0) })
        if isBrowser, let title = windowTitle?.lowercased() {
            for category in cfg.categories {
                if category.titlePatterns.contains(where: { title.contains($0) }) {
                    return category
                }
            }
        }

        return nil
    }

    /// Convenience: detect and return the hint string, or nil when no hint applies.
    static func hint(appName: String?, windowTitle: String?) -> String? {
        detect(appName: appName, windowTitle: windowTitle)?.hint
    }
}
