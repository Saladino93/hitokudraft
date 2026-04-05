import Foundation
import AppKit

/// Lightweight syntax highlighter for common programming languages.
/// Uses NSRegularExpression token patterns per language — no external dependencies.
/// Returns NSAttributedString with Atom One Dark palette, matching the overlay background.
///
/// Pattern application order: broad first (plain → comments → strings → numbers → keywords).
/// Later patterns win, so keywords override any earlier miscoloring.
enum CodeHighlighter {

    // MARK: - Atom One Dark palette

    private static let colorKeyword  = NSColor(srgbRed: 0.776, green: 0.471, blue: 0.867, alpha: 1) // #C678DD
    private static let colorString   = NSColor(srgbRed: 0.596, green: 0.765, blue: 0.471, alpha: 1) // #98C379
    private static let colorComment  = NSColor(srgbRed: 0.498, green: 0.518, blue: 0.557, alpha: 1) // #7F848E
    private static let colorNumber   = NSColor(srgbRed: 0.820, green: 0.604, blue: 0.400, alpha: 1) // #D19A66
    private static let colorFunction = NSColor(srgbRed: 0.380, green: 0.686, blue: 0.937, alpha: 1) // #61AFEF
    private static let colorType     = NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 1) // #E5C07B
    private static let colorPlain    = NSColor(srgbRed: 0.671, green: 0.698, blue: 0.745, alpha: 1) // #ABB2BF

    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: - Cache (bounded at 100 entries)

    private static var cache: [String: NSAttributedString] = [:]

    static func highlight(code: String, language lang: String) -> NSAttributedString {
        let norm = normalize(lang)
        let key = "\(norm)||||\(code)"
        if let hit = cache[key] { return hit }
        let result = apply(to: code, language: norm)
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = result
        return result
    }

    // MARK: - Language normalization

    private static func normalize(_ lang: String) -> String {
        switch lang.lowercased().trimmingCharacters(in: .whitespaces) {
        case "python", "py":                    return "python"
        case "javascript", "js",
             "typescript", "ts", "jsx", "tsx":  return "javascript"
        case "swift":                           return "swift"
        case "sh", "bash", "shell", "zsh":     return "bash"
        case "json":                            return "json"
        case "sql":                             return "sql"
        case "html", "xml", "htm", "svg":      return "html"
        case "css", "scss", "sass", "less":    return "css"
        case "java":                            return "java"
        case "go", "golang":                   return "go"
        case "rust", "rs":                      return "rust"
        case "c", "cpp", "c++", "cc", "h":    return "c"
        case "ruby", "rb":                      return "ruby"
        case "kotlin", "kt":                    return "kotlin"
        case "r":                               return "r"
        default:                                return "generic"
        }
    }

    // MARK: - Token patterns

    private struct Token {
        let pattern: String
        let color: NSColor
        var options: NSRegularExpression.Options = []
    }

    private static func apply(to code: String, language: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.foregroundColor: colorPlain, .font: codeFont]
        )

        for token in tokenPatterns(for: language) {
            guard let regex = try? NSRegularExpression(pattern: token.pattern, options: token.options) else { continue }
            let ns = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: ns) {
                result.addAttribute(.foregroundColor, value: token.color, range: match.range)
            }
        }
        return result
    }

    // swiftlint:disable function_body_length
    private static func tokenPatterns(for language: String) -> [Token] {
        switch language {

        case "json":
            return [
                Token(pattern: #":\s*"(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorType),     // keys
                Token(pattern: #"\b(true|false|null)\b"#, color: colorKeyword),
                Token(pattern: #"-?\b\d+\.?\d*(?:[eE][+-]?\d+)?\b"#, color: colorNumber),
            ]

        case "python":
            return [
                Token(pattern: #"#[^\n]*"#, color: colorComment),
                Token(pattern: #"\"\"\"[\s\S]*?\"\"\""#, color: colorString, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"\'\'\'[\s\S]*?\'\'\'"#, color: colorString, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"[fFrRbBuU]?"(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"[fFrRbBuU]?'(?:[^'\\]|\\.)*'"#, color: colorString),
                Token(pattern: #"\b(False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#, color: colorKeyword),
                Token(pattern: #"\b\d+\.?\d*(?:[eE][+-]?\d+)?\b"#, color: colorNumber),
                Token(pattern: #"@[a-zA-Z_]\w*"#, color: colorFunction),
                Token(pattern: #"(?<=def\s)[a-zA-Z_]\w*"#, color: colorFunction),
                Token(pattern: #"(?<=class\s)[A-Za-z_]\w*"#, color: colorType),
                Token(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#, color: colorType),
            ]

        case "swift":
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"\"\"\"[\s\S]*?\"\"\""#, color: colorString, options: [.dotMatchesLineSeparators]),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"\b(associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|precedencegroup|protocol|public|rethrows|static|struct|subscript|typealias|var|break|case|catch|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|throw|switch|where|while|as|Any|false|is|nil|self|Self|super|throws|true|try)\b"#, color: colorKeyword),
                Token(pattern: #"\b(Bool|Character|Double|Float|Int|Int8|Int16|Int32|Int64|String|UInt|UInt8|UInt16|UInt32|UInt64|Void|Never|Optional|Array|Dictionary|Set)\b"#, color: colorType),
                Token(pattern: #"\b\d+\.?\d*\b"#, color: colorNumber),
                Token(pattern: #"@[a-zA-Z_]\w*"#, color: colorKeyword),
                Token(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#, color: colorType),
                Token(pattern: #"(?<=func\s)[a-zA-Z_]\w*"#, color: colorFunction),
            ]

        case "javascript":
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"`(?:[^`\\]|\\.)*`"#, color: colorString),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"'(?:[^'\\]|\\.)*'"#, color: colorString),
                Token(pattern: #"\b(async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|from|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|with|yield)\b"#, color: colorKeyword),
                Token(pattern: #"\b\d+\.?\d*(?:[eE][+-]?\d+)?\b"#, color: colorNumber),
                Token(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#, color: colorType),
                Token(pattern: #"(?<=function\s)[a-zA-Z_]\w*"#, color: colorFunction),
            ]

        case "bash":
            return [
                Token(pattern: #"#[^\n]*"#, color: colorComment),
                Token(pattern: #""(?:[^"\\$]|\\.|\$\{[^}]*\}|\$[a-zA-Z_]\w*)*""#, color: colorString),
                Token(pattern: #"'[^']*'"#, color: colorString),
                Token(pattern: #"\b(break|case|continue|do|done|echo|elif|else|esac|exit|export|fi|for|function|if|in|local|read|return|select|set|shift|source|then|until|while)\b"#, color: colorKeyword),
                Token(pattern: #"\$[a-zA-Z_]\w*|\$\{[a-zA-Z_]\w*[^}]*\}"#, color: colorType),
                Token(pattern: #"\b\d+\b"#, color: colorNumber),
            ]

        case "sql":
            return [
                Token(pattern: #"--[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"'(?:[^'\\]|\\.)*'"#, color: colorString),
                Token(pattern: #"\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|FULL|CROSS|ON|AS|AND|OR|NOT|IN|EXISTS|BETWEEN|LIKE|IS|NULL|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|ADD|COLUMN|PRIMARY|KEY|FOREIGN|REFERENCES|INDEX|UNIQUE|VIEW|WITH|HAVING|GROUP|BY|ORDER|LIMIT|OFFSET|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END|CAST|COALESCE|COUNT|SUM|AVG|MIN|MAX)\b"#, color: colorKeyword, options: [.caseInsensitive]),
                Token(pattern: #"\b\d+\.?\d*\b"#, color: colorNumber),
            ]

        case "go":
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #"`[^`]*`"#, color: colorString),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"\b(break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|nil|true|false|iota)\b"#, color: colorKeyword),
                Token(pattern: #"\b(bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr|any)\b"#, color: colorType),
                Token(pattern: #"\b\d+\.?\d*\b"#, color: colorNumber),
                Token(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#, color: colorType),
                Token(pattern: #"(?<=func\s)[a-zA-Z_]\w*"#, color: colorFunction),
            ]

        case "rust":
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"\b(as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|union|unsafe|use|where|while)\b"#, color: colorKeyword),
                Token(pattern: #"\b(bool|char|f32|f64|i8|i16|i32|i64|i128|isize|str|u8|u16|u32|u64|u128|usize|String|Vec|Option|Result|Box|Rc|Arc|Cell|RefCell|HashMap|HashSet)\b"#, color: colorType),
                Token(pattern: #"\b\d+\.?\d*\b"#, color: colorNumber),
                Token(pattern: #"#\[[^\]]*\]"#, color: colorFunction),
                Token(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#, color: colorType),
                Token(pattern: #"(?<=fn\s)[a-zA-Z_]\w*"#, color: colorFunction),
            ]

        case "c":
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"'(?:[^'\\]|\\.)*'"#, color: colorString),
                Token(pattern: #"^\s*#\s*[a-z]+"#, color: colorKeyword, options: [.anchorsMatchLines]),
                Token(pattern: #"\b(auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|NULL|nullptr|true|false)\b"#, color: colorKeyword),
                Token(pattern: #"\b\d+\.?\d*[fFlLuU]*\b"#, color: colorNumber),
            ]

        default: // generic: just comments, strings, numbers
            return [
                Token(pattern: #"//[^\n]*"#, color: colorComment),
                Token(pattern: #"#[^\n]*"#, color: colorComment),
                Token(pattern: #"/\*[\s\S]*?\*/"#, color: colorComment, options: [.dotMatchesLineSeparators]),
                Token(pattern: #""(?:[^"\\]|\\.)*""#, color: colorString),
                Token(pattern: #"'(?:[^'\\]|\\.)*'"#, color: colorString),
                Token(pattern: #"\b\d+\.?\d*\b"#, color: colorNumber),
            ]
        }
    }
}
