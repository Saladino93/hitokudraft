import Foundation
import Security
import os

@MainActor
final class LicenseManager: ObservableObject {
    private static let log = Logger(subsystem: "com.hitokudraft.license", category: "activation")

    // MARK: - Published State

    @Published var isActivated: Bool
    @Published var licenseEmail: String?
    @Published var activationError: String?
    @Published var isActivating = false

    // MARK: - Constants

    private static let productID = "VsZWxa3HejVuIAYotNppYQ=="
    private static let maxUses = 2
    private static let keychainService = "com.hitokudraft.license"
    private static let keychainAccount = "gumroad-license-key"
    private static let reVerifyInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    // MARK: - Init

    init() {
        isActivated = UserDefaults.standard.bool(forKey: "licenseActivated")
        licenseEmail = UserDefaults.standard.string(forKey: "licenseEmail")
    }

    // MARK: - Activate

    func activate(licenseKey: String) async {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activationError = L("license.invalid_key")
            return
        }

        isActivating = true
        activationError = nil

        do {
            let response = try await verifyWithGumroad(licenseKey: trimmed, incrementUses: true)

            guard response.success else {
                activationError = L("license.invalid_key")
                isActivating = false
                return
            }

            guard response.uses <= Self.maxUses else {
                activationError = L("license.uses_exceeded")
                isActivating = false
                return
            }

            // Success — persist
            saveKeyToKeychain(trimmed)
            UserDefaults.standard.set(true, forKey: "licenseActivated")
            UserDefaults.standard.set(response.email, forKey: "licenseEmail")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "licenseLastVerifyDate")

            isActivated = true
            licenseEmail = response.email
            activationError = nil

            Self.log.info("License activated for \(response.email ?? "unknown", privacy: .public)")
        } catch {
            Self.log.error("Activation failed: \(error.localizedDescription, privacy: .public)")
            activationError = L("license.network_error")
        }

        isActivating = false
    }

    // MARK: - Deactivate

    func deactivate() {
        deleteKeyFromKeychain()
        UserDefaults.standard.removeObject(forKey: "licenseActivated")
        UserDefaults.standard.removeObject(forKey: "licenseEmail")
        UserDefaults.standard.removeObject(forKey: "licenseLastVerifyDate")

        isActivated = false
        licenseEmail = nil
        activationError = nil

        Self.log.info("License deactivated")
    }

    // MARK: - Silent Re-verification

    func reVerifyIfNeeded() async {
        guard isActivated else { return }

        let lastVerify = UserDefaults.standard.double(forKey: "licenseLastVerifyDate")
        let elapsed = Date().timeIntervalSince1970 - lastVerify
        guard elapsed >= Self.reVerifyInterval else { return }

        guard let key = loadKeyFromKeychain() else { return }

        do {
            let response = try await verifyWithGumroad(licenseKey: key, incrementUses: false)
            if response.success {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "licenseLastVerifyDate")
                if let email = response.email {
                    UserDefaults.standard.set(email, forKey: "licenseEmail")
                    licenseEmail = email
                }
                Self.log.info("Silent re-verification succeeded")
            } else {
                // Key revoked — deactivate
                deactivate()
                Self.log.warning("Silent re-verification: key revoked")
            }
        } catch {
            // Network failure — never block offline usage
            Self.log.info("Silent re-verification skipped (offline): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Gumroad API

    private struct GumroadVerifyResponse: Decodable {
        let success: Bool
        let uses: Int
        let email: String?

        private enum CodingKeys: String, CodingKey {
            case success, uses
            case purchase
        }

        private enum PurchaseKeys: String, CodingKey {
            case email
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            // `uses` is only present when success == true
            uses = (try? container.decode(Int.self, forKey: .uses)) ?? 0

            if let purchase = try? container.nestedContainer(keyedBy: PurchaseKeys.self, forKey: .purchase) {
                email = try? purchase.decode(String.self, forKey: .email)
            } else {
                email = nil
            }
        }
    }

    /// Percent-encode a value for use in application/x-www-form-urlencoded bodies.
    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+=&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func verifyWithGumroad(licenseKey: String, incrementUses: Bool) async throws -> GumroadVerifyResponse {
        var request = URLRequest(url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = "product_id=\(formEncode(Self.productID))&license_key=\(formEncode(licenseKey))&increment_uses_count=\(incrementUses)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GumroadVerifyResponse.self, from: data)
    }

    // MARK: - Keychain Helpers

    private func saveKeyToKeychain(_ key: String) {
        deleteKeyFromKeychain() // Remove old entry first

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: Data(key.utf8),
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("Keychain save failed: \(status)")
        }
    }

    private func loadKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
