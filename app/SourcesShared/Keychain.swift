import Foundation
#if !os(macOS)
import Security
#endif

/// Failure policy shared by the iOS/tvOS Keychain adapter and its executable tests.
///
/// A failed secure mutation may retain the caller's latest intent for this process only. The secret override is
/// deliberately not serializable. A separate persistent marker contains no secret and rejects stale secure state
/// after restart until a mutation succeeds. Every operation purges legacy plaintext slots.
final class KeychainFailureClosedStore: @unchecked Sendable {
    enum ReadResult {
        case value(String)
        case missing
        case failure
    }

    enum MutationResult {
        case success
        case failure
    }

    typealias ReadSecure = (_ account: String) -> ReadResult
    typealias WriteSecure = (_ value: String?, _ account: String) -> MutationResult
    typealias IsInvalidated = (_ account: String) -> Bool
    typealias MarkInvalidated = (_ account: String) -> Void
    typealias ClearInvalidated = (_ account: String) -> Void
    typealias PurgeAllLegacy = () -> Void
    typealias PurgeLegacy = (_ account: String) -> Void

    private enum VolatileValue {
        case value(String)
        case deleted
    }

    private let readSecure: ReadSecure
    private let writeSecure: WriteSecure
    private let isInvalidated: IsInvalidated
    private let markInvalidated: MarkInvalidated
    private let clearInvalidated: ClearInvalidated
    private let purgeAllLegacy: PurgeAllLegacy
    private let purgeLegacy: PurgeLegacy
    private let lock = NSLock()
    private var pendingOverrides: [String: VolatileValue] = [:]
    private var lastKnownValues: [String: VolatileValue] = [:]
    private var didSweepLegacy = false

    init(
        readSecure: @escaping ReadSecure,
        writeSecure: @escaping WriteSecure,
        isInvalidated: @escaping IsInvalidated,
        markInvalidated: @escaping MarkInvalidated,
        clearInvalidated: @escaping ClearInvalidated,
        purgeAllLegacy: @escaping PurgeAllLegacy,
        purgeLegacy: @escaping PurgeLegacy
    ) {
        self.readSecure = readSecure
        self.writeSecure = writeSecure
        self.isInvalidated = isInvalidated
        self.markInvalidated = markInvalidated
        self.clearInvalidated = clearInvalidated
        self.purgeAllLegacy = purgeAllLegacy
        self.purgeLegacy = purgeLegacy
    }

    func string(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        purgeLegacySlots(for: account)
        if let volatileOverride = pendingOverrides[account] {
            switch volatileOverride {
            case let .value(value):
                return value
            case .deleted:
                return nil
            }
        }

        guard !isInvalidated(account) else { return nil }

        switch readSecure(account) {
        case let .value(value):
            lastKnownValues[account] = .value(value)
            return value
        case .missing:
            lastKnownValues[account] = .deleted
            return nil
        case .failure:
            switch lastKnownValues[account] {
            case let .value(value):
                return value
            case .deleted, nil:
                return nil
            }
        }
    }

    func set(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }

        purgeLegacySlots(for: account)
        markInvalidated(account)
        switch writeSecure(value, account) {
        case .success:
            clearInvalidated(account)
            pendingOverrides.removeValue(forKey: account)
            if let value {
                lastKnownValues[account] = .value(value)
            } else {
                lastKnownValues[account] = .deleted
            }
        case .failure:
            if let value {
                pendingOverrides[account] = .value(value)
            } else {
                pendingOverrides[account] = .deleted
            }
        }
    }

    private func purgeLegacySlots(for account: String) {
        if !didSweepLegacy {
            purgeAllLegacy()
            didSweepLegacy = true
        }
        purgeLegacy(account)
    }
}

/// Small-secret store for the Stremio auth token.
///
/// On iOS/tvOS this uses the Keychain (generic password, readable after first unlock, not iCloud-synced).
/// If Security.framework is unavailable, a mutation survives only in process memory and is lost at restart.
/// Legacy plaintext fallback slots are purged on every operation and are never read or written.
///
/// On macOS the app is ad-hoc signed (no Developer ID), so every `SecItem` access against the LOGIN
/// keychain pops the "StremioX wants to use confidential information stored in '…' in your keychain"
/// password prompt; the item's ACL can never match a stable signing identity. To avoid that prompt
/// entirely, macOS stores the SAME accounts in an owner-only file under Application Support instead of
/// the system keychain. The public API is identical across platforms, so no caller changes.
enum Keychain {
    /// Prefix of legacy UserDefaults fallback slots that current builds purge and SettingsBackup filters.
    ///
    /// Declared OUTSIDE the platform `#if`, and non-private, because `SettingsBackup.secretKeyPrefixes` has to
    /// exclude these keys from the synced blob and the backup export on EVERY platform, not just the ones that
    /// used to write them: a token leaked by an old iPhone build travels inside the account's document, so a Mac
    /// still has to refuse to carry or apply one. Single source of truth on purpose, so the exclusion cannot
    /// drift away from the thing it excludes.
    static let fallbackKeyPrefix = "kcfallback."

    /// Device-local, non-secret marker for an account whose last Keychain mutation was not confirmed.
    ///
    /// The marker prevents an older secure value from reappearing after a failed delete or replacement and
    /// process restart. It stores only `true`, never credential bytes, and SettingsBackup excludes the prefix.
    static let invalidationKeyPrefix = "kcinvalidated."

#if os(macOS)
    // MARK: macOS file-backed store (no system keychain, no password prompt)

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
    // MARK: iOS / tvOS system Keychain

    private static func fallbackKey(_ account: String) -> String { fallbackKeyPrefix + account }
    private static func invalidationKey(_ account: String) -> String { invalidationKeyPrefix + account }

    private static let secureStore = KeychainFailureClosedStore(
        readSecure: { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data,
                      let value = String(data: data, encoding: .utf8)
                else { return .failure }
                return .value(value)
            case errSecItemNotFound:
                return .missing
            default:
                return .failure
            }
        },
        writeSecure: { value, account in
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
            ]
            let deleteStatus = SecItemDelete(base as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return .failure
            }

            guard let value else { return .success }
            guard let data = value.data(using: .utf8) else { return .failure }

            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? .success : .failure
        },
        isInvalidated: { account in
            UserDefaults.standard.object(forKey: invalidationKey(account)) != nil
        },
        markInvalidated: { account in
            UserDefaults.standard.set(true, forKey: invalidationKey(account))
        },
        clearInvalidated: { account in
            UserDefaults.standard.removeObject(forKey: invalidationKey(account))
        },
        purgeAllLegacy: {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(fallbackKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        },
        purgeLegacy: { account in
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        }
    )

    static func string(_ account: String) -> String? {
        secureStore.string(account)
    }

    static func set(_ value: String?, for account: String) {
        secureStore.set(value, for: account)
    }
#endif
}
