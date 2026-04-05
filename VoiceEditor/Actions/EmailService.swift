import AppKit
import Foundation

/// Opens a pre-filled compose window in the user's default mail client via mailto: URL.
/// Recipient is always left empty — the user fills it in before sending.
/// Never sends automatically — the user must press Send.
enum EmailService {

    enum EmailError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            "Could not build mailto: URL."
        }
    }

    static func composeEmail(subject: String, body: String) throws {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""   // no recipient — user fills in
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body",    value: body),
        ]

        guard let url = components.url else { throw EmailError.invalidURL }
        NSWorkspace.shared.open(url)
    }
}
