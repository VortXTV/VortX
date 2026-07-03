import Foundation

/// Portable export / import of the app's local settings, so a user can carry their
/// preferences across the StremioX -> VortX move (a later update ships VortX as a fresh app
/// identity, com.stremiox.* -> com.vortx.*, and therefore starts with empty local storage).
///
/// What it captures: this app's OWN UserDefaults domain, which is every preference the app
/// has written (theme, player toggles, audio output, source filters, profiles, server config,
/// seek step, resume positions, ...). It is read via `persistentDomain(forName:)`, so Apple's
/// global domain is excluded, and the keys are literal strings that do not depend on the bundle
/// id, so a StremioX backup repopulates the same keys when restored into VortX.
///
/// What it deliberately does NOT capture: the Stremio account token lives in the Keychain, not
/// UserDefaults, so it never lands in the backup file. The account (and with it the synced
/// library, add-ons, and history) comes back by signing in again. 0.4 is FREE to rename the
/// `@AppStorage` keys to `vortx.*`: restore runs every key through `migratedKey(_:)`, so a backup
/// written by an older StremioX build still applies. The only place the old names linger is inside
/// an old backup file, and that one function translates them on import.
enum SettingsBackup {
    static let schema = 1
    static let formatTag = "vortx-backup"

    /// Framework/OS keys that can appear in the app domain but are not our preferences.
    /// Filtered out so the backup stays app-only and a restore never re-seeds OS state.
    private static let skipPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "WebDatabase", "PK", "MetricKit", "INNext"]

    static func isAppPref(_ key: String) -> Bool {
        !skipPrefixes.contains { key.hasPrefix($0) }
    }

    /// PER-DEVICE keys that must NEVER sync or transfer between devices. The cross-device settings sync
    /// (VortXSyncManager) reuses this serialization as its `doc.settings` blob, so anything excluded here is
    /// excluded from BOTH the synced blob (makeBackup) and an incoming apply (decodeDomain/restore). Each
    /// device keeps its own value: the streaming-cache size depends on that device's free storage, and the
    /// streaming server is per-device (one device may point at a custom/local server). A device that pulls a
    /// peer's settings keeps its own cache/server choice; its own choice is never pushed up to overwrite others.
    static let deviceLocalKeys: Set<String> = [
        "stremiox.diskCacheBytes",   // Settings -> Streaming cache (sized to the device's own storage)
        "stremiox.serverURL",        // custom streaming server URL (per-device)
        "stremiox.videoUpscaling",   // Settings -> Video upscaling (per-device: standard on Apple TV, scaled on Mac)
    ]

    /// An app preference that is ALSO safe to sync/transfer (i.e. not a per-device-local key).
    static func isSyncable(_ key: String) -> Bool {
        isAppPref(key) && !deviceLocalKeys.contains(key)
    }

    /// 0.4 RENAME SEAM. When VortX renames its `@AppStorage` keys (the `stremiox.` prefix -> `vortx.`,
    /// plus the constant-defined keys), populate these so a backup written by an older StremioX build
    /// still applies. Empty in 0.3.5 (the keys are unchanged). Restore runs every key through
    /// `migratedKey` before writing it. Example for 0.4:
    ///   static let keyPrefixMigrations = ["stremiox.": "vortx."]
    ///   static let keyMigrations = ["legacy.exact.key": "vortx.newKey"]
    static let keyPrefixMigrations: [String: String] = [:]
    static let keyMigrations: [String: String] = [:]

    static func migratedKey(_ key: String) -> String {
        if let exact = keyMigrations[key] { return exact }
        for (old, new) in keyPrefixMigrations where key.hasPrefix(old) {
            return new + key.dropFirst(old.count)
        }
        return key
    }

    struct Envelope: Codable {
        var format: String
        var schema: Int
        var app: String
        var bundleID: String
        var createdAt: Date
        var keyCount: Int
        var payloadBase64: String   // binary plist of the filtered app defaults domain
    }

    enum RestoreError: LocalizedError {
        case notABackup
        case corruptPayload

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file is not a VortX backup."
            case .corruptPayload: return "This backup file is damaged and could not be read."
            }
        }
    }

    // MARK: Pure serialization (unit-testable, no UserDefaults / Bundle dependency)

    /// Wrap a defaults dictionary into the portable JSON envelope. The values pass through a
    /// binary property list, which natively round-trips every UserDefaults value type
    /// (Bool, Int, Double, String, Data, Date, arrays, dictionaries) that raw JSON cannot.
    static func encode(domain: [String: Any], bundleID: String, app: String, now: Date = Date()) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let env = Envelope(
            format: formatTag, schema: schema, app: app, bundleID: bundleID,
            createdAt: now, keyCount: domain.count, payloadBase64: plist.base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(env)
    }

    /// Validate and unwrap a backup file back into a defaults dictionary (app keys only).
    static func decodeDomain(from data: Data) throws -> [String: Any] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(Envelope.self, from: data), env.format == formatTag else {
            throw RestoreError.notABackup
        }
        guard let plistData = Data(base64Encoded: env.payloadBase64),
              let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let pairs = object as? [String: Any]
        else {
            throw RestoreError.corruptPayload
        }
        return pairs.filter { isSyncable($0.key) }   // never apply a peer's per-device keys (cache size, server URL)
    }

    // MARK: App I/O

    /// Suggested filename for the exporter (the `.json` extension is appended from the content type).
    static func defaultFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return "VortX-Backup-\(df.string(from: Date()))"
    }

    /// Serialize the app's own preferences into a portable, human-inspectable JSON file.
    static func makeBackup() throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let full = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let domain = full.filter { isSyncable($0.key) }   // exclude per-device keys (cache size, server URL)
        let app = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "VortX"
        return try encode(domain: domain, bundleID: bundleID, app: app)
    }

    /// Apply a backup file. Merges keys (overwriting matching ones, leaving the rest), so a
    /// partial backup never wipes settings it does not mention. Returns the number of keys
    /// applied. A relaunch is recommended afterwards so every store re-reads cleanly.
    @discardableResult
    static func restore(from data: Data) throws -> Int {
        let pairs = try decodeDomain(from: data)
        let defaults = UserDefaults.standard
        for (key, value) in pairs {
            defaults.set(value, forKey: migratedKey(key))
        }
        return pairs.count
    }
}
