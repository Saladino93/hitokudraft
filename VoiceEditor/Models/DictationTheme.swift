import SwiftUI

/// Color themes for the dictation overlay pill.
enum DictationTheme: String, CaseIterable, Identifiable {
    case neonViolet
    case neonBlue
    case darkNeon
    case frostedGlass
    case sunset
    case obsidian

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

    // MARK: - Pill Colors

    var pillBackground: Color {
        switch self {
        case .neonViolet:   return Color(red: 0.16, green: 0.07, blue: 0.27, opacity: 0.96)
        case .neonBlue:     return Color(red: 0.07, green: 0.12, blue: 0.27, opacity: 0.96)
        case .darkNeon:     return Color(red: 0.05, green: 0.14, blue: 0.11, opacity: 0.96)
        case .frostedGlass: return Color.white.opacity(0.07)
        case .sunset:       return Color(red: 0.22, green: 0.07, blue: 0.10, opacity: 0.96)
        case .obsidian:     return Color(red: 0.047, green: 0.047, blue: 0.055, opacity: 0.96)
        }
    }

    var borderColor: Color {
        switch self {
        case .neonViolet:   return Color(red: 0.63, green: 0.39, blue: 1.0, opacity: 0.25)
        case .neonBlue:     return Color(red: 0.31, green: 0.51, blue: 1.0, opacity: 0.25)
        case .darkNeon:     return Color(red: 0.24, green: 0.78, blue: 0.55, opacity: 0.25)
        case .frostedGlass: return Color.white.opacity(0.12)
        case .sunset:       return Color(red: 1.0, green: 0.47, blue: 0.31, opacity: 0.25)
        case .obsidian:     return Color.white.opacity(0.08)
        }
    }

    var accentColor: Color {
        switch self {
        case .neonViolet:   return Color(red: 0.67, green: 0.47, blue: 1.0)     // #AA77FF
        case .neonBlue:     return Color(red: 0.33, green: 0.53, blue: 1.0)     // #5588FF
        case .darkNeon:     return Color(red: 0.27, green: 0.80, blue: 0.53)    // #44CC88
        case .frostedGlass: return Color.white.opacity(0.50)
        case .sunset:       return Color(red: 1.0, green: 0.53, blue: 0.40)     // #FF8866
        case .obsidian:     return Color(white: 0.533)                        // #888888
        }
    }

    var speakingAccentColor: Color {
        switch self {
        case .neonViolet:   return Color(red: 0.33, green: 0.80, blue: 0.67)    // #55CCAA
        case .neonBlue:     return Color(red: 0.33, green: 0.80, blue: 0.67)    // #55CCAA
        case .darkNeon:     return Color(red: 0.47, green: 0.67, blue: 1.0)     // #77AAFF
        case .frostedGlass: return Color(red: 0.71, green: 0.86, blue: 1.0, opacity: 0.6)
        case .sunset:       return Color(red: 1.0, green: 0.80, blue: 0.47)     // #FFCC77
        case .obsidian:     return Color(white: 0.667)                        // #AAAAAA
        }
    }

    var badgeBg: Color {
        switch self {
        case .frostedGlass, .obsidian: return Color.white.opacity(0.08)
        default:                       return accentColor.opacity(0.15)
        }
    }

    var badgeText: Color {
        switch self {
        case .neonViolet:   return Color(red: 0.73, green: 0.53, blue: 1.0)    // #BB88FF
        case .neonBlue:     return Color(red: 0.47, green: 0.60, blue: 1.0)    // #7799FF
        case .darkNeon:     return Color(red: 0.33, green: 0.87, blue: 0.60)   // #55DD99
        case .frostedGlass: return Color.white.opacity(0.55)
        case .sunset:       return Color(red: 1.0, green: 0.60, blue: 0.40)    // #FF9966
        case .obsidian:     return Color.white.opacity(0.45)
        }
    }

    /// True for themes that use vibrancy/blur instead of a solid background.
    var usesMaterial: Bool { self == .frostedGlass }

    // MARK: - Backward Compatibility

    var panelBackground: Color { pillBackground }
    var panelBorder: Color { borderColor }
    var accent: Color { accentColor }

    // MARK: - Localized Strings

    var displayName: String {
        switch self {
        case .neonViolet:   return L("theme.neon_violet.name")
        case .neonBlue:     return L("theme.neon_blue.name")
        case .darkNeon:     return L("theme.dark_neon.name")
        case .frostedGlass: return "Frosted Glass"
        case .sunset:       return "Sunset"
        case .obsidian:     return "Obsidian"
        }
    }

    var displayDescription: String {
        switch self {
        case .neonViolet:   return L("theme.neon_violet.desc")
        case .neonBlue:     return L("theme.neon_blue.desc")
        case .darkNeon:     return L("theme.dark_neon.desc")
        case .frostedGlass: return "Translucent with vibrancy"
        case .sunset:       return "Warm amber and coral"
        case .obsidian:     return "Near-black stealth"
        }
    }
}
