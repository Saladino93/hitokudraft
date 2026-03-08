import NaturalLanguage

enum LanguageDetector {
    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return "en" }
        return language.rawValue
    }
}
