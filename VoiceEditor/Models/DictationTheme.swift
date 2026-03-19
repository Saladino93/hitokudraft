import SwiftUI

/// Neon color themes for the dictation overlay panel.
enum DictationTheme: String, CaseIterable, Identifiable {
    case neonViolet
    case neonBlue
    case darkNeon

    var id: String { rawValue }

    /// Default theme used when no preference is stored.
    static let `default`: DictationTheme = .neonViolet

    /// Reads the current theme from UserDefaults, falling back to `.neonViolet`.
    static var current: DictationTheme {
        guard let raw = UserDefaults.standard.string(forKey: "dictationTheme"),
              let theme = DictationTheme(rawValue: raw) else {
            return .default
        }
        return theme
    }

    // MARK: - Colors

    var panelBackground: Color {
        switch self {
        case .neonViolet: return Color(red: 28/255, green: 16/255, blue: 40/255)
        case .neonBlue:   return Color(red: 12/255, green: 22/255, blue: 41/255)
        case .darkNeon:   return Color(red: 10/255, green: 15/255, blue: 10/255)
        }
    }

    var panelBorder: Color {
        switch self {
        case .neonViolet: return Color.purple.opacity(0.20)
        case .neonBlue:   return Color.blue.opacity(0.22)
        case .darkNeon:   return Color.green.opacity(0.15)
        }
    }

    var accent: Color {
        switch self {
        case .neonViolet: return Color(red: 176/255, green: 106/255, blue: 255/255)
        case .neonBlue:   return Color(red: 91/255, green: 159/255, blue: 255/255)
        case .darkNeon:   return Color(red: 61/255, green: 232/255, blue: 155/255)
        }
    }

    // MARK: - Localized Strings

    var displayName: String {
        switch self {
        case .neonViolet: return L("theme.neon_violet.name")
        case .neonBlue:   return L("theme.neon_blue.name")
        case .darkNeon:   return L("theme.dark_neon.name")
        }
    }

    var displayDescription: String {
        switch self {
        case .neonViolet: return L("theme.neon_violet.desc")
        case .neonBlue:   return L("theme.neon_blue.desc")
        case .darkNeon:   return L("theme.dark_neon.desc")
        }
    }
}
