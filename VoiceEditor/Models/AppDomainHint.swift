import Foundation

/// Broad domain categories for the user's active app.
enum AppCategory {
    case email, messaging, coding, notes, terminal, unknown
}

/// Detects the domain of the user's active app and produces a soft hint for the LLM.
enum AppDomainHint {

    // MARK: - Known browsers (triggers tier-2 windowTitle inspection)

    private static let browsers: Set<String> = [
        "safari", "google chrome", "chrome", "firefox", "arc",
        "microsoft edge", "brave browser", "opera", "orion", "vivaldi",
    ]

    // MARK: - Tier 1: native app name → category

    private static let appNameRules: [(pattern: String, category: AppCategory)] = [
        // Email
        ("mail", .email), ("outlook", .email), ("spark", .email),
        ("thunderbird", .email), ("mimestream", .email), ("superhuman", .email),
        // Messaging
        ("messages", .messaging), ("slack", .messaging), ("discord", .messaging),
        ("telegram", .messaging), ("whatsapp", .messaging), ("signal", .messaging),
        ("microsoft teams", .messaging),
        // Coding
        ("xcode", .coding), ("visual studio code", .coding), ("cursor", .coding),
        ("zed", .coding), ("sublime text", .coding), ("nova", .coding),
        ("intellij", .coding), ("pycharm", .coding), ("webstorm", .coding),
        // Notes
        ("notes", .notes), ("notion", .notes), ("obsidian", .notes),
        ("bear", .notes), ("craft", .notes), ("ulysses", .notes),
        ("ia writer", .notes), ("scrivener", .notes),
        // Terminal
        ("terminal", .terminal), ("iterm", .terminal), ("warp", .terminal),
        ("alacritty", .terminal), ("kitty", .terminal),
    ]

    // MARK: - Tier 2: windowTitle keywords (for browser windows)

    private static let titleRules: [(pattern: String, category: AppCategory)] = [
        // Email
        ("gmail", .email), ("protonmail", .email), ("fastmail", .email),
        ("outlook", .email),
        // Messaging
        ("slack", .messaging), ("discord", .messaging), ("telegram", .messaging),
        ("whatsapp", .messaging), ("messenger", .messaging),
        // Coding
        ("github.com", .coding), ("gitlab.com", .coding),
        // Notes
        ("notion.so", .notes), ("docs.google.com", .notes),
    ]

    // MARK: - Detection

    /// Detect the app domain from the active app name and window title.
    static func detect(appName: String?, windowTitle: String?) -> AppCategory {
        guard let app = appName?.lowercased() else { return .unknown }

        // Tier 1: direct app name match (first match wins)
        for rule in appNameRules {
            if app.contains(rule.pattern) {
                return rule.category
            }
        }

        // Tier 2: if app is a known browser, inspect the window title
        if browsers.contains(app) || browsers.contains(where: { app.contains($0) }) {
            if let title = windowTitle?.lowercased() {
                for rule in titleRules {
                    if title.contains(rule.pattern) {
                        return rule.category
                    }
                }
            }
        }

        return .unknown
    }

    // MARK: - Hint text

    /// Returns a hedged, one-sentence domain hint for the given category, or nil for `.unknown`.
    static func hintText(for category: AppCategory) -> String? {
        switch category {
        case .email:
            return "The user appears to be in an email app. If the request relates to email, use appropriate greeting/sign-off conventions and professional tone."
        case .messaging:
            return "The user appears to be in a messaging app. If the request relates to a message, keep the tone conversational and the length brief."
        case .coding:
            return "The user appears to be in a code editor. If the request relates to code, use proper code formatting and technical language."
        case .notes:
            return "The user appears to be in a writing/notes app. If the request relates to writing, use clear structure with appropriate headings or bullet points."
        case .terminal:
            return "The user appears to be in a terminal. If the request relates to commands, output shell-ready syntax."
        case .unknown:
            return nil
        }
    }

    /// Convenience: detect and return the hint in one call, or nil when no hint applies.
    static func hint(appName: String?, windowTitle: String?) -> String? {
        hintText(for: detect(appName: appName, windowTitle: windowTitle))
    }
}
