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
    case blockedHost
    case requestFailed(statusCode: Int)
    case notHTML(contentType: String)
    case timeout
    case emptyContent
    case htmlParsingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The URL is invalid or unreachable."
        case .blockedHost:
            return "Local and private network addresses cannot be fetched, and only standard web ports (80 and 443) are allowed."
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
        guard OutboundURLPolicy.isAllowed(url) else {
            throw WebFetchError.blockedHost
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
            // The delegate re-checks every redirect hop against OutboundURLPolicy.
            (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectPolicyDelegate())
        } catch let error as URLError where error.code == .timedOut {
            throw WebFetchError.timeout
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidURL
        }

        if let finalURL = httpResponse.url, !OutboundURLPolicy.isAllowed(finalURL) {
            throw WebFetchError.blockedHost
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

// MARK: - Outbound URL Policy

/// Decides whether the assistant may contact a URL. Rejects anything that could reach
/// the user's own machine or local network: loopback, link-local, private (RFC 1918 /
/// ULA), CGNAT, multicast/reserved IP literals, `localhost` / `.local` / `.internal`
/// and single-label names, and any port other than 80/443.
///
/// Checks the literal host only. A public name that resolves to a private address
/// (DNS rebinding, `localtest.me`-style names) is out of scope.
enum OutboundURLPolicy {

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if let port = url.port, port != 80, port != 443 {
            return false
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        if let blocked = isBlockedIPLiteral(host) { return !blocked }

        if host == "localhost" { return false }
        for suffix in [".localhost", ".local", ".internal", ".home.arpa"] where host.hasSuffix(suffix) {
            return false
        }
        // Single-label names ("router", "nas") resolve via search domains to the LAN.
        return host.contains(".")
    }

    /// `nil` when `host` is not an IP literal; otherwise whether that address is blocked.
    private static func isBlockedIPLiteral(_ host: String) -> Bool? {
        // inet_aton also accepts the legacy shorthand forms ("127.1", "2130706433",
        // "0x7f.0.0.1") that URL loading would happily connect to.
        var v4 = in_addr()
        if !host.contains(":"), inet_aton(host, &v4) != 0 {
            return isBlockedIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            let embeddedV4 = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isBlockedIPv4(embeddedV4)                  // ::ffff:a.b.c.d (IPv4-mapped)
            }
            if b[0..<12].allSatisfy({ $0 == 0 }) {
                return true                                       // ::, ::1, IPv4-compatible
            }
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
                return isBlockedIPv4(embeddedV4)                  // 64:ff9b::/96 (NAT64)
            }
            if b[0] & 0xfe == 0xfc { return true }                // fc00::/7 unique local
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }  // fe80::/10 link-local
            if b[0] == 0xfe, b[1] & 0xc0 == 0xc0 { return true }  // fec0::/10 site-local (deprecated)
            if b[0] == 0xff { return true }                       // ff00::/8 multicast
            return false
        }
        return nil
    }

    private static func isBlockedIPv4(_ a: UInt32) -> Bool {
        func inRange(_ base: UInt32, _ prefix: UInt32) -> Bool {
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return a & mask == base & mask
        }
        return inRange(0x0000_0000, 8)      // 0.0.0.0/8 "this network"
            || inRange(0x0A00_0000, 8)      // 10.0.0.0/8
            || inRange(0x6440_0000, 10)     // 100.64.0.0/10 CGNAT
            || inRange(0x7F00_0000, 8)      // 127.0.0.0/8 loopback
            || inRange(0xA9FE_0000, 16)     // 169.254.0.0/16 link-local
            || inRange(0xAC10_0000, 12)     // 172.16.0.0/12
            || inRange(0xC000_0000, 24)     // 192.0.0.0/24 IETF protocol assignments
            || inRange(0xC0A8_0000, 16)     // 192.168.0.0/16
            || inRange(0xC612_0000, 15)     // 198.18.0.0/15 benchmarking
            || inRange(0xE000_0000, 4)      // 224.0.0.0/4 multicast
            || inRange(0xF000_0000, 4)      // 240.0.0.0/4 reserved + broadcast
    }
}

/// Re-applies `OutboundURLPolicy` to every redirect hop, so a public page can't bounce
/// the request to a local address. A refused redirect returns the 3xx response itself,
/// which `fetchHTML` then reports as a failed request.
private final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, OutboundURLPolicy.isAllowed(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

// MARK: - URL Detection

enum URLDetector {

    /// Extracts the first URL from a text string, if any.
    static func firstURL(in text: String) -> URL? {
        allURLs(in: text).first
    }

    /// Extracts every URL from a text string, in order of appearance.
    static func allURLs(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }

    /// Comparison key for the `fetch_url` allow-list: host (lowercased, without a
    /// leading `www.`) + path (without trailing slash) + query. The scheme is left out
    /// (http and https are equivalent here) because a spoken "example.com" is detected
    /// as `http://example.com` while the model will usually request `https://`.
    /// Fragments are ignored. `nil` for non-http(s) URLs.
    static func allowListKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        var key = host + path
        if let query = url.query, !query.isEmpty { key += "?" + query }
        return key
    }
}
