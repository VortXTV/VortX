import Foundation
import Security

/// Small-secret store for the Stremio auth token. Prefers the Keychain (generic password, readable
/// after first unlock, not iCloud-synced). If the Keychain is unavailable, which happens on the
/// unsigned Simulator and can happen on a re-signed sideload where the keychain-access-group does not
/// match, it falls back to UserDefaults so the token is never silently lost. On a normally signed
/// device the Keychain path is used and nothing is mirrored to UserDefaults.
enum Keychain {
    private static func fallbackKey(_ account: String) -> String { "kcfallback." + account }

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        // Keychain miss or unavailable → fall back to UserDefaults.
        return UserDefaults.standard.string(forKey: fallbackKey(account))
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing item

        guard let value, let data = value.data(using: .utf8) else {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))   // clearing the token
            return
        }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)

        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))   // Keychain is authoritative
        } else {
            // Keychain unavailable (unsigned Simulator, entitlement mismatch) → keep it working.
            UserDefaults.standard.set(value, forKey: fallbackKey(account))
        }
    }
}
