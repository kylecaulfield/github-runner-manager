import Foundation
import Security

/// Stores the GitHub fine-grained PAT in the login Keychain as a generic password item.
/// The app needs NO Keychain entitlement for its own item. The PAT is never written to disk,
/// UserDefaults, or logs — Keychain only.
enum KeychainStore {
    static let service = "com.github.runnermanager.pat"
    static let account = "github-fine-grained-pat"

    static func savePAT(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw AppError.keychain(errSecParam) }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)   // clean upsert: remove any existing item first
        var add = base
        add[kSecValueData as String] = data
        // ThisDeviceOnly: never syncs to iCloud Keychain / other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError.keychain(status) }
    }

    static func readPAT() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppError.keychain(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func clearPAT() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.keychain(status) }
    }

    // ASSUMPTION: spec's `(try? readPAT()) ?? nil != nil` mis-parses because `??` binds looser than `!=`;
    // parenthesize the flatten so we compare the unwrapped String? against nil (preserves intended semantics).
    static func hasPAT() -> Bool { ((try? readPAT()) ?? nil) != nil }
}
