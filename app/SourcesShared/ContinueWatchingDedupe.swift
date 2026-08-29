import Foundation

/// Order-stable Continue Watching deduplication shared by the live engine preview and owner-resume recovery.
/// Raw ids are authoritative. A display fingerprint is intentionally accepted only when type, title, and poster
/// are all present, so two unrelated same-name titles are never collapsed on title alone.
enum ContinueWatchingDedupe {
    struct Identity: Equatable {
        let id: String
        let type: String
        let name: String
        let poster: String?
    }

    static func filterUnique<Item>(
        _ items: [Item],
        seenIDs: inout Set<String>,
        seenFingerprints: inout Set<String>,
        identity: (Item) -> Identity
    ) -> [Item] {
        items.filter { item in
            let value = identity(item)
            let id = normalizeID(value.id)
            guard !id.isEmpty, seenIDs.insert(id).inserted else { return false }

            guard let fingerprint = strongFingerprint(
                type: value.type,
                name: value.name,
                poster: value.poster
            ) else { return true }
            guard seenFingerprints.insert(fingerprint).inserted else {
                seenIDs.remove(id)
                return false
            }
            return true
        }
    }

    private static func normalizeID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func strongFingerprint(type: String, name: String, poster: String?) -> String? {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = name
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        let normalizedPoster = poster?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedType.isEmpty, !normalizedName.isEmpty, !normalizedPoster.isEmpty else { return nil }
        return "\(normalizedType)\u{1f}\(normalizedName)\u{1f}\(normalizedPoster)"
    }
}

/// Pure membership comparison used by the CoreBridge meta-details no-op suppressor. Array order is not state;
/// episode membership is, including the same-count replacement that previously left detail markers stale.
enum WatchedMembershipPolicy {
    static func changed(_ current: [String]?, _ next: [String]?) -> Bool {
        Set(current ?? []) != Set(next ?? [])
    }
}

/// Select the freshest overlay snapshot for account sync. Only the active profile has a live dictionary;
/// inactive profiles continue to use their persisted caches.
enum OverlayWatchSyncPolicy {
    static func snapshot<ID: Equatable, Entry>(
        requestedID: ID,
        activeID: ID?,
        live: [String: Entry],
        persisted: [String: Entry]
    ) -> [String: Entry] {
        requestedID == activeID ? live : persisted
    }
}
