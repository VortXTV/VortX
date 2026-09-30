import Foundation
import CoreFoundation

/// The account document is the only source allowed to create an owner-bound local-history
/// recommendation snapshot after a VortX credential transition.  In particular, this mapper never
/// consults CoreBridge's resident library or Continue Watching arrays: those arrays can still belong to
/// the owner that was selected before the current account was authenticated.
enum BecauseYouWatchedDocumentHistory {
    struct Snapshot {
        let library: [CoreCWItem]
        let continueWatching: [CoreCWItem]
    }

    /// Map the decrypted account document directly into the recommendation inputs.  The optional
    /// `removedIDs` argument is the local tombstone set; document tombstones are folded here as well so
    /// the mapper remains safe when called before the normal sync tombstone fold.
    static func snapshot(
        from document: [String: Any],
        removedIDs: Set<String> = []
    ) -> Snapshot {
        let vortx = document["vortx"] as? [String: Any]
        let rawLibrary = (vortx?["library"] as? [[String: Any]])
            ?? (document["library"] as? [[String: Any]])
            ?? []
        let tombstones = Set(
            removedIDs
                .map(normalizedID)
                .filter { !$0.isEmpty }
                + ((vortx?["deletedLibrary"] as? [String]) ?? []).map(normalizedID)
        )

        var seen = Set<String>()
        var library: [CoreCWItem] = []
        library.reserveCapacity(rawLibrary.count)

        for raw in rawLibrary {
            guard let item = mapItem(raw),
                  !tombstones.contains(item.id),
                  seen.insert(item.id).inserted else { continue }
            library.append(item)
        }

        // Membership is not watch evidence.  A positive source-owned offset is the minimum proof for
        // Continue Watching; missing/zero counters remain zero and are intentionally not synthesized.
        let continueWatching = library.filter { $0.state.timeOffset > 0 }
        return Snapshot(library: library, continueWatching: continueWatching)
    }

    private static func mapItem(_ raw: [String: Any]) -> CoreCWItem? {
        guard let rawID = raw["id"] as? String,
              let id = supportedCatalogID(rawID) else { return nil }
        guard (raw["removed"] as? Bool) != true,
              (raw["temp"] as? Bool) != true else { return nil }

        guard let rawName = raw["name"] as? String else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let rawType = raw["type"] as? String,
              let type = LibraryWatchedMutationPolicy.normalizedCatalogType(rawType) else { return nil }

        guard let timeOffsetSeconds = nonnegativeFiniteSeconds(raw["t"]),
              let durationSeconds = nonnegativeFiniteSeconds(raw["d"]) else { return nil }
        let poster = (raw["poster"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoID = (raw["v"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastWatched = (raw["lastWatched"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return CoreCWItem(
            id: id,
            type: type,
            name: name,
            poster: poster.flatMap { $0.isEmpty ? nil : $0 },
            state: CoreLibState(
                timeOffset: timeOffsetSeconds * 1000,
                duration: durationSeconds * 1000,
                videoId: videoID.flatMap { $0.isEmpty ? nil : $0 },
                lastWatched: lastWatched.flatMap { $0.isEmpty ? nil : $0 },
                flaggedWatched: 0,
                timesWatched: 0),
            removed: nil,
            temp: nil)
    }

    private static func supportedCatalogID(_ raw: String) -> String? {
        let id = normalizedID(raw)
        switch DetailMetaRecoveryPolicy.catalogIDShape(id) {
        case .imdb, .tmdb, .tvdb, .kitsu:
            return id
        case .unsupported:
            return nil
        }
    }

    private static func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Missing source fields are valid legacy rows and mean "no position".  Present malformed values are
    /// rejected instead of being coerced into a plausible watch position.
    private static func nonnegativeFiniteSeconds(_ raw: Any?) -> Double? {
        guard let raw else { return 0 }
        let value: Double
        if let number = raw as? NSNumber {
            // JSONSerialization bridges both numbers and booleans to NSNumber, and Apple Foundation can
            // report an integer NSNumber as `raw is Bool`.  Only CoreFoundation's Boolean type is a
            // boolean wire value; numeric 0/1 must remain valid offsets/durations.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            value = number.doubleValue
        } else if let integer = raw as? Int {
            value = Double(integer)
        } else if let double = raw as? Double {
            value = double
        } else {
            return nil
        }
        guard value.isFinite, value >= 0, value <= Double.greatestFiniteMagnitude / 1000 else { return nil }
        return value
    }
}
