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
        let ownerHistoryProfileID = "00000000-0000-0000-0000-00000000A11C"
        let rawOwnerHistory = (((vortx?["byProfile"] as? [String: Any])?[ownerHistoryProfileID]
            as? [String: Any])?["ownerHistory"] as? [[String: Any]]) ?? []
        let tombstones = Set(
            removedIDs
                .map(normalizedID)
                .filter { !$0.isEmpty }
                + ((vortx?["deletedLibrary"] as? [String]) ?? []).map(normalizedID)
        )

        var seen = Set<String>()
        var library: [CoreCWItem] = []
        library.reserveCapacity(rawLibrary.count + rawOwnerHistory.count)

        // History rows come first intentionally: a genuine player event is stronger evidence than an
        // engine library row, whose initial lastWatched can be construction metadata.  It is accepted
        // into this recommendation-only snapshot, never into the saved-library model or tombstones.
        for raw in rawOwnerHistory {
            guard validOwnerHistoryRow(raw), let item = mapItem(raw), seen.insert(item.id).inserted else { continue }
            library.append(item)
        }

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

    /// Map durable local owner-history rows for the live Continue Watching union.  The caller supplies
    /// only rows admitted by OwnerHistoryStore, keeping this mapper Foundation-testable and ensuring an
    /// opaque/malformed peer row cannot become playback UI state.
    static func ownerHistoryItems(from rows: [[String: Any]]) -> [CoreCWItem] {
        var seen = Set<String>()
        return rows.compactMap { raw in
            guard let item = mapItem(raw), item.state.timeOffset > 0,
                  item.state.duration > 0, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    /// A document is untrusted at this layer.  Validate the owner-history causal tuple separately
    /// from normal library rows so a peer's partial/future schema cannot become local CW evidence.
    private static func validOwnerHistoryRow(_ raw: [String: Any]) -> Bool {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let type = raw["type"] as? String, type == "movie" || type == "series",
              let video = raw["v"] as? String, !video.isEmpty,
              let event = nonnegativeFiniteSeconds(raw["eventEpochMs"]),
              event > 0, event.rounded(.towardZero) == event,
              event <= 9_007_199_254_740_991,
              let lastWatched = raw["lastWatched"] as? String, isoMillis(lastWatched) > 0 else { return false }
        if let watched = raw["watched"], !isNull(watched), !(watched is String) { return false }
        for key in ["currentVideoWatched", "wholeTitleWatched"]
        where raw[key].map({ !isNull($0) }) == true {
            guard let value = raw[key] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        }
        if let timesWatched = raw["timesWatched"], !isNull(timesWatched),
           !isUnsigned32(timesWatched) { return false }
        return true
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

    private static func isUnsigned32(_ raw: Any) -> Bool {
        guard let value = nonnegativeFiniteSeconds(raw),
              value.rounded(.towardZero) == value else { return false }
        return value <= Double(UInt32.max)
    }

    private static func isNull(_ raw: Any) -> Bool { raw is NSNull }

    private static func isoMillis(_ value: String) -> Double {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return (fractional.date(from: value) ?? plain.date(from: value))?.timeIntervalSince1970 ?? 0
    }
}
