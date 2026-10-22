import Foundation

// MARK: - Web Search Tool

/// Searches the web via DuckDuckGo and returns snippets.
struct WebSearchTool: Tool {
    let name = "web_search"
    let toolDescription = "Search the web for current information. Use for factual questions, current events, or when you need up-to-date data."
    let parameterDescription = "{\"query\": \"your search query\"}"

    let searchService: any WebSearchService

    func execute(arguments: [String: String]) async throws -> String {
        guard let query = arguments["query"], !query.isEmpty else {
            return "Error: Missing or empty 'query' parameter."
        }

        let results = try await searchService.search(query: query, maxResults: 5)

        guard !results.isEmpty else {
            return "No results found for: \(query)"
        }

        return results.enumerated().map { index, result in
            var entry = "[\(index + 1)] \(result.title)"
            if let url = result.url {
                entry += " (\(url.absoluteString))"
            }
            entry += "\n\(result.snippet)"
            return entry
        }.joined(separator: "\n\n")
    }
}

// MARK: - URL Fetch Tool

/// Fetches a web page and returns clean text content.
struct FetchURLTool: Tool {
    let name = "fetch_url"
    let toolDescription = "Fetch and read a web page the user mentioned. Only links the user said can be fetched."
    let parameterDescription = "{\"url\": \"https://example.com/page\"}"

    let fetchService: any WebFetchService

    /// Without a request context nothing was provided by the user, so every URL is rejected.
    func execute(arguments: [String: String]) async throws -> String {
        try await execute(arguments: arguments, context: ToolRequestContext())
    }

    func execute(arguments: [String: String], context: ToolRequestContext) async throws -> String {
        guard let urlStr = arguments["url"],
              let url = URL(string: urlStr),
              url.scheme == "http" || url.scheme == "https" else {
            return "Error: Missing or invalid 'url' parameter. Must be an http(s) URL."
        }

        // Only links the user mentioned in their own command. Stops a page, the screen,
        // or the model itself from steering requests to arbitrary addresses.
        guard let key = URLDetector.allowListKey(for: url),
              context.userProvidedURLKeys.contains(key) else {
            return "Error: URL not provided by the user; only links the user mentioned can be fetched."
        }

        let text = try await fetchService.fetchArticleText(from: url, budget: 2000)

        guard !text.isEmpty else {
            return "The page at \(urlStr) returned no readable content."
        }

        return text
    }
}
