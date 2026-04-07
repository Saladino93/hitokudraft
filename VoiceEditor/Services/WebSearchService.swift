import Foundation

// MARK: - Protocol

/// Searches the web and returns structured results.
protocol WebSearchService: Sendable {
    /// Returns up to `maxResults` search results for the given query.
    func search(query: String, maxResults: Int) async throws -> [SearchResult]
}

// MARK: - Result

struct SearchResult: Sendable {
    let title: String
    let url: URL?
    let snippet: String
}

// MARK: - Errors

enum WebSearchError: LocalizedError {
    case invalidQuery
    case requestFailed(statusCode: Int)
    case decodingFailed
    case timeout
    case noResults

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "The search query is empty or invalid."
        case .requestFailed(let code):
            return "Search request failed with HTTP status \(code)."
        case .decodingFailed:
            return "Failed to decode search results."
        case .timeout:
            return "The search request timed out."
        case .noResults:
            return "No results found for this query."
        }
    }
}

// MARK: - DuckDuckGo Implementation

/// Uses DuckDuckGo's HTML search endpoint — returns actual web results, no API key needed.
/// Parses the lightweight HTML response to extract titles, URLs, and snippets.
struct DuckDuckGoSearchService: WebSearchService {

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.invalidQuery }

        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw WebSearchError.invalidQuery
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
        ]
        guard let url = components.url else { throw WebSearchError.invalidQuery }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpMethod = "POST"
        request.httpBody = "q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WebSearchError.timeout
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WebSearchError.requestFailed(statusCode: httpResponse.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.decodingFailed
        }

        return parseHTMLResults(html: html, maxResults: maxResults)
    }
}

// MARK: - DuckDuckGo HTML Parsing

private extension DuckDuckGoSearchService {

    /// Parses DuckDuckGo's lightweight HTML results page.
    /// Results are in `<a class="result__a">` (title+URL) and `<a class="result__snippet">` (snippet).
    func parseHTMLResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Split by result blocks — each result is in a <div class="result ...">
        let blocks = html.components(separatedBy: "class=\"result__a\"")
        // Skip first block (it's the page header before any results)
        for block in blocks.dropFirst() {
            guard results.count < maxResults else { break }

            // Extract URL from href="..."
            let url = extractAttribute(from: block, attribute: "href")
                .flatMap { cleanDDGUrl($0) }
                .flatMap { URL(string: $0) }

            // Extract title: text between > and </a>
            let title = extractTagContent(from: block)

            // Extract snippet: look for result__snippet in the same block area
            let snippet = extractSnippet(from: block)

            guard let title, !title.isEmpty else { continue }

            results.append(SearchResult(
                title: title,
                url: url,
                snippet: snippet ?? ""
            ))
        }

        return results
    }

    /// Extracts an HTML attribute value: attribute="VALUE"
    func extractAttribute(from html: String, attribute: String) -> String? {
        let pattern = attribute + "=\""
        guard let start = html.range(of: pattern) else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    /// Extracts text content after the first > until </a>
    func extractTagContent(from html: String) -> String? {
        guard let gtIdx = html.firstIndex(of: ">") else { return nil }
        let afterGt = html[html.index(after: gtIdx)...]
        guard let endTag = afterGt.range(of: "</a>") else { return nil }
        let raw = String(afterGt[afterGt.startIndex..<endTag.lowerBound])
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts snippet text from the result block.
    func extractSnippet(from block: String) -> String? {
        guard let snippetStart = block.range(of: "result__snippet") else { return nil }
        let rest = block[snippetStart.upperBound...]
        guard let gtIdx = rest.firstIndex(of: ">") else { return nil }
        let afterGt = rest[rest.index(after: gtIdx)...]
        guard let endTag = afterGt.range(of: "</") else { return nil }
        let raw = String(afterGt[afterGt.startIndex..<endTag.lowerBound])
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DuckDuckGo wraps URLs in a redirect: //duckduckgo.com/l/?uddg=ENCODED_URL
    /// Extract the actual URL from the uddg parameter.
    func cleanDDGUrl(_ raw: String) -> String {
        if raw.contains("uddg="),
           let components = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        // Direct URL (no redirect wrapper)
        if raw.hasPrefix("//") { return "https:" + raw }
        return raw
    }
}
