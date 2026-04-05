import AppKit
import Foundation

/// Opens a pre-filled compose window in the user's default mail client via mailto: URL.
/// If `to` is a raw email address (contains "@"), it is placed in the mailto: recipient field.
/// If `to` is a spoken name with no "@", the compose window opens with an empty recipient —
/// the user fills in the address themselves before sending.
/// Never sends automatically — the user must press Send.
enum EmailService {

    enum EmailError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            "Could not build mailto: URL."
        }
    }

    static func composeEmail(to: String, subject: String, body: String) async throws {
        // Only use `to` as the recipient if it looks like a real email address.
        let recipient = to.contains("@") ? to : ""
        try openMailto(address: recipient, subject: subject, body: body)
    }

    // MARK: - Private

    private static func openMailto(address: String, subject: String, body: String) throws {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address   // empty string → no recipient pre-filled
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body",    value: body),
        ]

        guard let url = components.url else { throw EmailError.invalidURL }
        NSWorkspace.shared.open(url)
    }
}
