import Foundation
import Security
import CryptoKit
import os

@MainActor
final class LicenseManager: ObservableObject {
    private static let log = Logger(subsystem: "com.hitokudraft.license", category: "activation")

    // MARK: - Published State

    @Published var isActivated: Bool = false
    @Published var licenseEmail: String?
    @Published var activationError: String?
    @Published var isActivating = false

    // MARK: - Constants

    private static let productID = "VsZWxa3HejVuIAYotNppYQ=="
    private static let maxUses = 2
    private static let keychainService = "com.hitokudraft.license"
    private static let keychainKeyAccount = "gumroad-license-key"
    private static let keychainTokenAccount = "license-token"
    private static let offlineGracePeriod: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    /// HMAC key stored as raw bytes — not discoverable via `strings` binary scan.
    /// Finding this requires disassembling the HMAC verification logic.
    private static let integrityKey: SymmetricKey = {
        let k: [UInt8] = [
            0xa3, 0x1f, 0x7c, 0xe2, 0x5b, 0x94, 0xd0, 0x68,
            0x3e, 0xf1, 0xab, 0x47, 0x09, 0xc6, 0x82, 0xdd,
            0x55, 0x1a, 0xb8, 0x73, 0xe4, 0x0f, 0x96, 0x2c,
            0x6d, 0x38, 0xfa, 0x85, 0x11, 0xc7, 0x4e, 0xa0
        ]
        return SymmetricKey(data: Data(k))
    }()

    // MARK: - License Token (Keychain-stored, HMAC-signed)

    private struct LicenseToken: Codable {
        let email: String
        let activatedAt: TimeInterval
        var lastVerifiedAt: TimeInterval
        var signature: String
    }

    private enum LicenseError: Error {
        case responseIntegrityFailure
    }

    // MARK: - Init

    init() {
        #if DEBUG
        isActivated = true
        licenseEmail = "dev@hitokudraft.local"
        return
        #endif

        if let token = loadAndVerifyToken() {
            isActivated = true
            licenseEmail = token.email
        } else if migrateFromUserDefaults() {
            // Migration from pre-1.1.0 created a signed token
            if let token = loadAndVerifyToken() {
                isActivated = true
                licenseEmail = token.email
            }
        }
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

            // Cross-check: reject refunded / disputed / chargebacked licenses
            guard !response.refunded && !response.disputed && !response.chargebacked else {
                activationError = L("license.invalid_key")
                isActivating = false
                Self.log.warning("Activation rejected: refunded=\(response.refunded) disputed=\(response.disputed) chargebacked=\(response.chargebacked)")
                return
            }

            guard response.uses <= Self.maxUses else {
                activationError = L("license.uses_exceeded")
                isActivating = false
                return
            }

            // Success — persist to Keychain with HMAC signature
            let now = Date().timeIntervalSince1970
            let email = response.email ?? ""
            saveKeyToKeychain(trimmed)
            let token = createSignedToken(licenseKey: trimmed, email: email, activatedAt: now, lastVerifiedAt: now)
            saveTokenToKeychain(token)

            isActivated = true
            licenseEmail = response.email
            activationError = nil

            // Email in UserDefaults is for display convenience only (not a trust anchor)
            UserDefaults.standard.set(response.email, forKey: "licenseEmail")

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
        deleteTokenFromKeychain()
        UserDefaults.standard.removeObject(forKey: "licenseEmail")
        // Clean up any legacy keys from pre-1.1.0
        UserDefaults.standard.removeObject(forKey: "licenseActivated")
        UserDefaults.standard.removeObject(forKey: "licenseLastVerifyDate")

        isActivated = false
        licenseEmail = nil
        activationError = nil

        Self.log.info("License deactivated")
    }

    // MARK: - Silent Re-verification (every launch, 7-day offline grace)

    func reVerifyIfNeeded() async {
        #if DEBUG
        return
        #endif
        guard isActivated else { return }
        guard let key = loadKeyFromKeychain() else {
            // License key missing from Keychain — deactivate
            deactivate()
            return
        }
        guard let token = loadAndVerifyToken() else {
            // Token signature invalid — possible tampering
            deactivate()
            return
        }

        do {
            let response = try await verifyWithGumroad(licenseKey: key, incrementUses: false)
            if response.success && !response.refunded && !response.disputed && !response.chargebacked {
                // Update token with fresh verification timestamp
                let now = Date().timeIntervalSince1970
                let updated = createSignedToken(
                    licenseKey: key,
                    email: response.email ?? token.email,
                    activatedAt: token.activatedAt,
                    lastVerifiedAt: now
                )
                saveTokenToKeychain(updated)
                if let email = response.email {
                    UserDefaults.standard.set(email, forKey: "licenseEmail")
                    licenseEmail = email
                }
                Self.log.info("Launch re-verification succeeded")
            } else {
                // Key revoked, refunded, or disputed — deactivate
                deactivate()
                Self.log.warning("Launch re-verification: key no longer valid")
            }
        } catch {
            // Network failure — allow offline usage within grace period
            let elapsed = Date().timeIntervalSince1970 - token.lastVerifiedAt
            if elapsed > Self.offlineGracePeriod {
                deactivate()
                Self.log.warning("Offline grace period expired (\(Int(elapsed / 86400))d), deactivated")
            } else {
                Self.log.info("Re-verification skipped (offline, \(Int((Self.offlineGracePeriod - elapsed) / 86400))d grace remaining)")
            }
        }
    }

    // MARK: - HMAC Token Management

    private func createSignedToken(licenseKey: String, email: String, activatedAt: TimeInterval, lastVerifiedAt: TimeInterval) -> LicenseToken {
        let message = "\(licenseKey)|\(email)|\(Int(activatedAt))|\(Int(lastVerifiedAt))"
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: Self.integrityKey)
        let signature = Data(hmac).base64EncodedString()
        return LicenseToken(email: email, activatedAt: activatedAt, lastVerifiedAt: lastVerifiedAt, signature: signature)
    }

    private func verifyTokenSignature(_ token: LicenseToken, licenseKey: String) -> Bool {
        let message = "\(licenseKey)|\(token.email)|\(Int(token.activatedAt))|\(Int(token.lastVerifiedAt))"
        guard let signatureData = Data(base64Encoded: token.signature) else { return false }
        // Constant-time comparison via CryptoKit
        return HMAC<SHA256>.isValidAuthenticationCode(signatureData, authenticating: Data(message.utf8), using: Self.integrityKey)
    }

    private func loadAndVerifyToken() -> LicenseToken? {
        guard let key = loadKeyFromKeychain() else { return nil }
        guard let tokenData = loadTokenDataFromKeychain() else { return nil }
        guard let token = try? JSONDecoder().decode(LicenseToken.self, from: tokenData) else { return nil }
        guard verifyTokenSignature(token, licenseKey: key) else {
            Self.log.warning("Token signature verification failed — possible tampering")
            return nil
        }
        return token
    }

    // MARK: - Migration from UserDefaults (pre-1.1.0)

    @discardableResult
    private func migrateFromUserDefaults() -> Bool {
        let wasActivated = UserDefaults.standard.bool(forKey: "licenseActivated")
        guard wasActivated else { return false }
        guard let key = loadKeyFromKeychain() else {
            // Flag set without a key — invalid state, clean up
            cleanupLegacyDefaults()
            return false
        }

        let email = UserDefaults.standard.string(forKey: "licenseEmail") ?? ""
        let lastVerify = UserDefaults.standard.double(forKey: "licenseLastVerifyDate")
        let now = Date().timeIntervalSince1970

        // Re-save key with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        saveKeyToKeychain(key)

        let token = createSignedToken(
            licenseKey: key,
            email: email,
            activatedAt: lastVerify > 0 ? lastVerify : now,
            lastVerifiedAt: lastVerify > 0 ? lastVerify : now
        )
        saveTokenToKeychain(token)
        cleanupLegacyDefaults()

        Self.log.info("Migrated license from UserDefaults to signed Keychain token")
        return true
    }

    private func cleanupLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "licenseActivated")
        UserDefaults.standard.removeObject(forKey: "licenseLastVerifyDate")
    }

    // MARK: - Gumroad API

    private struct GumroadVerifyResponse: Decodable {
        let success: Bool
        let uses: Int
        let email: String?
        let refunded: Bool
        let disputed: Bool
        let chargebacked: Bool
        let echoedLicenseKey: String?

        private enum CodingKeys: String, CodingKey {
            case success, uses, purchase
        }

        private enum PurchaseKeys: String, CodingKey {
            case email, refunded, disputed, chargebacked
            case licenseKey = "license_key"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            // `uses` is only present when success == true
            uses = (try? container.decode(Int.self, forKey: .uses)) ?? 0

            if let purchase = try? container.nestedContainer(keyedBy: PurchaseKeys.self, forKey: .purchase) {
                email = try? purchase.decode(String.self, forKey: .email)
                refunded = (try? purchase.decode(Bool.self, forKey: .refunded)) ?? false
                disputed = (try? purchase.decode(Bool.self, forKey: .disputed)) ?? false
                chargebacked = (try? purchase.decode(Bool.self, forKey: .chargebacked)) ?? false
                echoedLicenseKey = try? purchase.decode(String.self, forKey: .licenseKey)
            } else {
                email = nil
                refunded = false
                disputed = false
                chargebacked = false
                echoedLicenseKey = nil
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
        let response = try JSONDecoder().decode(GumroadVerifyResponse.self, from: data)

        // Cross-check: verify the echoed license key matches what we sent
        if response.success, let echoed = response.echoedLicenseKey, echoed != licenseKey {
            Self.log.warning("License key mismatch in response — possible MITM")
            throw LicenseError.responseIntegrityFailure
        }

        return response
    }

    // MARK: - Keychain Helpers

    private func saveKeyToKeychain(_ key: String) {
        deleteKeyFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainKeyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("Keychain key save failed: \(status)")
        }
    }

    private func loadKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainKeyAccount,
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
            kSecAttrAccount as String: Self.keychainKeyAccount,
        ]

        SecItemDelete(query as CFDictionary)
    }

    private func saveTokenToKeychain(_ token: LicenseToken) {
        deleteTokenFromKeychain()
        guard let data = try? JSONEncoder().encode(token) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainTokenAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("Keychain token save failed: \(status)")
        }
    }

    private func loadTokenDataFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainTokenAccount,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
