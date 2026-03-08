import Foundation

enum Instructions {
    static let byLanguage: [String: String] = [
        "en": """
            Fix all grammar, punctuation, and spelling mistakes. \
            Preserve the original meaning and tone.
            """,
        "it": """
            Correggi tutti gli errori di grammatica, punteggiatura e ortografia. \
            Preserva il significato e il tono originali.
            """,
        "fr": """
            Corrigez toutes les erreurs de grammaire, de ponctuation et d'orthographe. \
            Préservez le sens et le ton d'origine.
            """,
        "de": """
            Korrigiere alle Grammatik-, Zeichensetzungs- und Rechtschreibfehler. \
            Behalte die ursprüngliche Bedeutung und den Ton bei.
            """,
    ]

    static func forLanguage(_ code: String) -> String {
        byLanguage[code] ?? byLanguage["en"]!
    }
}
