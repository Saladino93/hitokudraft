import Foundation
import AppKit

// MARK: - Protocol

/// Fetches a web page and returns its main content as clean plain text.
protocol WebFetchService: Sendable {
    /// Fetches the page at `url` and returns up to `budget` characters of article text.
    func fetchArticleText(from url: URL, budget: Int) async throws -> String
}

// MARK: - Errors

enum WebFetchError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int)
    case notHTML(contentType: String)
    case timeout
    case emptyContent
    case htmlParsingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The URL is invalid or unreachable."
        case .requestFailed(let code):
            return "Web request failed with HTTP status \(code)."
        case .notHTML(let contentType):
            return "Expected HTML content but received \(contentType)."
        case .timeout:
            return "The web request timed out after 10 seconds."
        case .emptyContent:
            return "The page returned no readable content."
        case .htmlParsingFailed(let underlying):
            return "Failed to parse HTML: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Concrete Implementation

/// Uses `URLSession` and `NSAttributedString` HTML parsing to extract clean article text.
/// Stateless and `Sendable` -- no stored properties.
struct ReadabilityWebFetcher: WebFetchService {

    func fetchArticleText(from url: URL, budget: Int) async throws -> String {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw WebFetchError.invalidURL
        }

        let html = try await fetchHTML(from: url)
        let plainText = try await extractPlainText(from: html)
        let cleaned = collapseWhitespace(plainText)

        guard !cleaned.isEmpty else {
            throw WebFetchError.emptyContent
        }

        return truncate(cleaned, to: budget)
    }
}

// MARK: - Private Methods

private extension ReadabilityWebFetcher {

    func fetchHTML(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WebFetchError.timeout
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidURL
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebFetchError.requestFailed(statusCode: httpResponse.statusCode)
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           !contentType.contains("html") {
            throw WebFetchError.notHTML(contentType: contentType)
        }

        return data
    }

    @MainActor
    func extractPlainText(from htmlData: Data) throws -> String {
        // NSAttributedString HTML parsing requires the main thread on macOS.
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        do {
            let attributed = try NSAttributedString(data: htmlData, options: options, documentAttributes: nil)
            return attributed.string
        } catch {
            throw WebFetchError.htmlParsingFailed(error)
        }
    }

    func collapseWhitespace(_ text: String) -> String {
        // Replace sequences of whitespace/newlines with a single space,
        // then trim leading/trailing whitespace.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    func truncate(_ text: String, to budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard text.count > budget else { return text }
        let truncated = String(text.prefix(budget))
        // Avoid cutting in the middle of a word -- backtrack to last space.
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex...lastSpace])
        }
        return truncated
    }
}

// MARK: - URL Detection

enum URLDetector {

    /// Extracts the first URL from a text string, if any.
    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        return match.url
    }
}
