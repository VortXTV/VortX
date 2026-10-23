import Foundation

/// Retain extensions at the boundaries the legacy serializer rewrites. Membership and all
/// known values still come from its resolved replacement, including omitted optional fields.
/// This is deliberately not a union of old/new arrays: a removed profile/title stays removed.
enum LegacySyncRetention {
    private indirect enum Shape: Sendable {
        case object(Set<String>, [String: Shape])
        case rows(String, Shape)
        case map(Shape)
    }

    private static func object(_ keys: String, _ children: [String: Shape] = [:]) -> Shape {
        .object(Set(keys.split(separator: " ").map(String.init)), children)
    }

    private static let playback = object("audioLang subtitleLang forcedPolicy forced subFont subSize subColor subBackground subSizeScale subBrightness sourceTypeOrder useAddonOrder safetyMode instantOnly hideDeadTorrents hdrOnly excludeAV1 excludeKeywords includeKeywords keywordsAreRegex maxResolution maxFileSizeGB minResolution hideUnknownResolution preferredAudioOnly preferKeywords avoidBehavior autoPickBest")
    private static let discovery = object("hiddenCatalogs catalogOrder hiddenHubCategories regionOverrideCaptured regionOverride filtersCaptured filtersData selectedProviders providerOrder tabVisibilityCaptured hideLiveTab hideDiscoverTab hideLibraryTab hideSearchTab showCollectionsHome showCollectionsDiscover continueWatchingSource continueWatchingWindow")
    private static let ranking = object("addonOrder sourceTypeOrder useAddonOrder")
    private static let addonPreferences = object("disabledAddonURLsOverride rankingOverride", ["rankingOverride": ranking])
    private static let profile = object("id name avatar accentID oled textScale pin usesOwnAccount email isOwner familyEdit playback discovery disabledAddons addonPreferences isKids",
        ["playback": playback, "discovery": discovery, "addonPreferences": addonPreferences])
    private static let summarySettings = object("avatar accent oled textScale isKids playback", ["playback": playback])
    private static let summaryProfile = object("id name locked main familyEdit pinHash settings disabledAddons", ["settings": summarySettings])
    private static let libraryRow = object("id name type poster t d v lastWatched w ma ua")
    private static let watchedRow = object("w ma ua")
    private static let removal = object("keys removedAt")
    private static let stamps = object("removedAt addedAt")
    private static let bucket = object("library watched removed ownerHistory", [
        "library": .rows("id", libraryRow), "watched": .map(watchedRow),
        "removed": .rows("keys", removal)])
    // Add-on descriptors are untyped engine values. Preserve extension keys, while treating the
    // engine's known descriptor/manifest/flags as the authority for fields it understands.
    private static let addon = object("transportUrl name manifest flags", [
        "manifest": object("id version name description logo background types catalogs resources idPrefixes behaviorHints", [
            "behaviorHints": object("adult p2p configurable configurationRequired")]),
        "flags": object("official protected")])
    private static let summaryShape = object("profiles updatedAt roster rosterModified ownerWatched byProfile library addons addonsOwnedAt activeProfile deletedProfiles deletedAddons deletedAddonsTs deletedLibrary deletedLibraryTs", [
        "profiles": .rows("id", summaryProfile), "roster": .rows("id", profile),
        "ownerWatched": .map(object("t v w u a")),
        "byProfile": .map(bucket), "library": .rows("id", libraryRow), "addons": .rows("transportUrl", addon),
        "deletedAddonsTs": .map(stamps), "deletedLibraryTs": .map(stamps)])

    private static func identity(_ raw: Any?) -> String? {
        if let value = raw as? String { return UUID(uuidString: value)?.uuidString ?? value }
        if let values = raw as? [String] { return values.sorted().joined(separator: "\u{0}") }
        return nil
    }

    private static func retain(_ prior: Any?, _ replacement: Any?, shape: Shape) -> Any? {
        switch shape {
        case .object(let owned, let children):
            // A cleared known container is itself a deletion, including its old children.
            // Retaining a future-only playback object would also break the Codable roster.
            guard let replacement else { return nil }
            if !(replacement is [String: Any]) { return replacement }
            let old = prior as? [String: Any] ?? [:]
            let new = replacement as? [String: Any] ?? [:]
            var result = old.filter { !owned.contains($0.key) }
            for (key, value) in new { result[key] = value }
            for (key, child) in children {
                result[key] = retain(old[key], new[key], shape: child)
            }
            return result
        case .rows(let key, let row):
            guard let rows = replacement as? [[String: Any]] else { return replacement }
            let priorRows = prior as? [[String: Any]] ?? []
            let byID = Dictionary(priorRows.compactMap { item -> (String, [String: Any])? in
                identity(item[key]).map { ($0, item) }
            }, uniquingKeysWith: { first, _ in first })
            return rows.map { item in
                retain(identity(item[key]).flatMap { byID[$0] }, item, shape: row) as? [String: Any] ?? item
            }
        case .map(let row):
            guard let rows = replacement as? [String: Any] else { return replacement }
            let old = prior as? [String: Any] ?? [:]
            return rows.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = retain(old[entry.key], entry.value, shape: row)
            }
        }
    }

    static func summary(existing: [String: Any]?, replacement: [String: Any]) -> [String: Any] {
        var result = retain(existing, replacement, shape: summaryShape) as? [String: Any] ?? replacement
        // Tombstones also exclude opaque extensions of a removed row, never resurrecting it.
        let deleted = Set((replacement["deletedProfiles"] as? [String] ?? []).compactMap { identity($0) })
        for key in ["profiles", "roster"] {
            if let rows = result[key] as? [[String: Any]] {
                result[key] = rows.filter { !deleted.contains(identity($0["id"]) ?? "") }
            }
        }
        if let buckets = result["byProfile"] as? [String: Any] {
            result["byProfile"] = buckets.filter { !deleted.contains(identity($0.key) ?? "") }
        }
        return result
    }

    /// SettingsBackup stores the full roster as JSON Data in a binary property list. Codable
    /// drops unknown fields on local decode; retain them by live id before writing that carrier.
    static func rosterData(existing: Any?, replacement: Data) -> Data? {
        guard let rows = try? JSONSerialization.jsonObject(with: replacement) as? [[String: Any]] else { return nil }
        var prior: Any?
        if let existing {
            guard let bytes = existing as? Data,
                  let decoded = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { return nil }
            prior = decoded
        }
        guard let merged = retain(prior, rows, shape: .rows("id", profile)) else { return nil }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    static func settingsEnvelope(existing: Any?, replacement: Data) -> Data? {
        let prior = (existing as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let next = try? JSONSerialization.jsonObject(with: replacement),
              let merged = retain(prior, next, shape: object("format schema app bundleID createdAt keyCount payloadBase64")) else { return nil }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }
}
