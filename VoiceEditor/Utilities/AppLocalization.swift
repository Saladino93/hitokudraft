import Foundation

enum AppLocalization {
    static let supportedLanguages = ["en", "it", "fr", "es"]

    static let displayNames: [String: String] = [
        "en": "English",
        "it": "Italiano",
        "fr": "Français",
        "es": "Español",
    ]

    /// Detects the best initial language from the system's preferred languages.
    /// Falls back to "en" if no supported language matches.
    static func detectInitialLanguage() -> String {
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix(2))
            if supportedLanguages.contains(code) {
                return code
            }
        }
        return "en"
    }

    /// Loads a localized string from the appropriate `.lproj` bundle.
    static func localized(_ key: String, language: String) -> String {
        guard let bundlePath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath)
        else {
            // Fallback: try English bundle, then return the key itself
            if language != "en",
               let enPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
               let enBundle = Bundle(path: enPath)
            {
                return enBundle.localizedString(forKey: key, value: key, table: nil)
            }
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Localized string with format arguments.
    static func localized(_ key: String, language: String, _ args: CVarArg...) -> String {
        let format = localized(key, language: language)
        return String(format: format, arguments: args)
    }
}

// MARK: - Concise global accessor

/// Short global function for localized strings. Reads `appLanguage` from UserDefaults.
func L(_ key: String) -> String {
    let lang = UserDefaults.standard.string(forKey: "appLanguage")
        ?? AppLocalization.detectInitialLanguage()
    return AppLocalization.localized(key, language: lang)
}

/// Short global function for localized strings with format arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = UserDefaults.standard.string(forKey: "appLanguage")
        ?? AppLocalization.detectInitialLanguage()
    let format = AppLocalization.localized(key, language: lang)
    return String(format: format, arguments: args)
}
