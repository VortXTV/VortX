import Foundation
#if !os(macOS)
import Security
#endif

/// Small-secret store for the Stremio auth token.
///
/// On iOS/tvOS this prefers the Keychain (generic password, readable after first unlock, not
/// iCloud-synced). If the Keychain is unavailable — which happens on the unsigned Simulator and can
/// happen on a re-signed sideload where the keychain-access-group does not match — it falls back to
/// UserDefaults so the token is never silently lost. On a normally signed device the Keychain path is
/// used and nothing is mirrored to UserDefaults.
///
/// On macOS the app is ad-hoc signed (no Developer ID), so every `SecItem` access against the LOGIN
/// keychain pops the "StremioX wants to use confidential information stored in '…' in your keychain"
/// password prompt — the item's ACL can never match a stable signing identity. To avoid that prompt
/// entirely, macOS stores the SAME accounts in an owner-only file under Application Support instead of
/// the system keychain. The public API is identical across platforms, so no caller changes.
enum Keychain {
#if os(macOS)
    // MARK: macOS — file-backed store (no system keychain, no password prompt)

    /// `~/Library/Application Support/StremioX/credentials.plist`, a `[String: String]` map keyed by
    /// the same account names the Keychain path uses (e.g. "stremiox.authKey",
    /// "stremiox.authKey.<profileID>"). Owner-only: dir 0700, file 0600.
    private static let storeURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("StremioX", isDirectory: true)
            .appendingPathComponent("credentials.plist", isDirectory: false)
    }()

    private static let queue = DispatchQueue(label: "com.stremiox.keychain.file")

    static func string(_ account: String) -> String? {
        queue.sync { load()[account] }
    }

    static func set(_ value: String?, for account: String) {
        queue.sync {
            var store = load()
            if let value {
                store[account] = value
            } else {
                store.removeValue(forKey: account)   // delete = remove the key
            }
            save(store)
        }
    }

    /// Missing file = empty store (= nil per key). We deliberately do NOT read the old system keychain
    /// here: that read is exactly what triggers the password prompt. The user simply re-signs in once,
    /// after which everything lives in the file.
    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (decoded as? [String: String]) ?? [:]
    }

    private static func save(_ store: [String: String]) {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        // Create the dir owner-only (0700) if missing.
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }

        guard let data = try? PropertyListSerialization.data(fromPropertyList: store,
                                                             format: .binary, options: 0) else { return }
        // Atomic write so a crash mid-write can't corrupt the store.
        do {
            try data.write(to: storeURL, options: [.atomic])
            // Atomic writes replace the inode, so re-assert owner-only perms (0600) afterwards.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            NSLog("%@", "[Keychain] failed to persist credentials file: \(error)")
        }
    }
#else
    // MARK: iOS / tvOS — system Keychain with UserDefaults fallback (unchanged)

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
#endif
}
