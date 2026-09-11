import Foundation

/// Pure, testable merge policy for an OVERLAY profile's watch entries on the sync-down leg
/// (`ProfileStore.applyRemoteOverlay`). Replaces the old monotone UNION of `watchedVideoIds`, which
/// could only ever grow: an unmark (watched -> unwatched) delivered from a peer was resurrected by the
/// union on every device and pushed back, so "unwatch" never stuck account-wide.
///
/// Semantics (per-video LWW clocks + snapshot LWW scalars):
///  - Each video id carries two optional wall-clock (ms) stamps: `markedAt` (last explicit mark) and
///    `unmarkedAt` (last explicit unmark). A video is effectively watched iff `markedAt > unmarkedAt`.
///    Stamps merge by pointwise max, so independent episode operations from different devices survive.
///  - Legacy rows (peers that never stamped clocks) contribute their ids additively ONLY where no clock
///    record exists; any clock record — mark or unmark — supersedes legacy membership for that id.
///  - Scalar progress (videoId / timeOffsetMs / durationMs / lastWatched) is last-writer-wins by the
///    REAL parsed lastWatched clock: a NEWER inbound snapshot with a SMALLER watched set shrinks it
///    (unmark delivery in either order), and an older inbound snapshot is never unioned back.
enum OverlayWatchMergePolicy {
    /// Durable per-profile watched-history bound. The CW-rail `library` rows stay trimmed at 120 (a
    /// render-rail bound), but durable watched ids ride the untrimmed `watched` map up to this limit so
    /// an old, fully-watched series below the rail cut still reaches a fresh device. 2000 rows is far
    /// under the inbound parse limit (OverlayWatchInboundPolicy.parseLimit) and keeps the account doc
    /// bounded without silently wiping synced history.
    static let durableWatchedEntryLimit = 1_800

    /// Parse a WatchEntry.lastWatched ISO string (or raw ms number) into wall-clock ms. 0 = no clock.
    static func lastWatchedMillis(_ raw: String) -> Double {
        OwnerLibraryPositionPolicy.lastWatchedMillis(raw)
    }

    /// Pointwise-max merge of the per-video mark/unmark clocks of two entries.
    static func mergedClocks(existing: WatchEntry, incoming: WatchEntry) -> (markedAt: [String: Double], unmarkedAt: [String: Double]) {
        var marked = existing.markedAt ?? [:]
        var unmarked = existing.unmarkedAt ?? [:]
        for (id, at) in incoming.markedAt ?? [:] where at > (marked[id] ?? 0) { marked[id] = at }
        for (id, at) in incoming.unmarkedAt ?? [:] where at > (unmarked[id] ?? 0) { unmarked[id] = at }
        return (marked, unmarked)
    }

    /// Effective watched ids from merged clocks: marked strictly after the last unmark (and a real stamp).
    static func effectiveWatchedIds(markedAt: [String: Double], unmarkedAt: [String: Double]) -> [String] {
        markedAt.keys.filter { id in
            let m = markedAt[id] ?? 0
            return m > 0 && m > (unmarkedAt[id] ?? 0)
        }.sorted()
    }

    /// Merge one inbound entry into the local one. Pure: returns the merged entry (or the existing one
    /// unchanged). Never unions an OLDER snapshot's ids back over a newer one.
    static func mergeEntry(existing: WatchEntry, incoming: WatchEntry) -> WatchEntry {
        let clocks = mergedClocks(existing: existing, incoming: incoming)
        var merged = existing
        let existingClock = lastWatchedMillis(existing.lastWatched)
        let incomingClock = lastWatchedMillis(incoming.lastWatched)
        if incomingClock > existingClock {
            // Newer inbound snapshot: adopt its scalar progress wholesale (rewind / zero / episode
            // change all propagate). Only fall back to local metadata where the inbound row is bare.
            merged.videoId = incoming.videoId
            merged.timeOffsetMs = incoming.timeOffsetMs
            merged.durationMs = incoming.durationMs
            merged.lastWatched = incoming.lastWatched
            if !incoming.name.isEmpty { merged.name = incoming.name }
            if !incoming.type.isEmpty { merged.type = incoming.type }
            merged.poster = incoming.poster ?? existing.poster
        }
        merged.markedAt = clocks.markedAt.isEmpty ? nil : clocks.markedAt
        merged.unmarkedAt = clocks.unmarkedAt.isEmpty ? nil : clocks.unmarkedAt
        // Legacy snapshots lack per-video operation clocks. They must still be scalar-LWW as
        // snapshots: unioning an older legacy set would resurrect a newer unwatch.
        let legacyWinner = incomingClock > existingClock
            ? incoming.watchedVideoIds : existing.watchedVideoIds
        merged.watchedVideoIds = resolvedWatchedIds(
            markedAt: clocks.markedAt, unmarkedAt: clocks.unmarkedAt,
            legacySnapshot: legacyWinner)
        return merged
    }

    /// Watched ids after the merge: clock-decided ids plus legacy (clock-less) ids no clock record
    /// supersedes. Deterministic order so tests and equality hold.
    static func resolvedWatchedIds(
        markedAt: [String: Double], unmarkedAt: [String: Double],
        legacySnapshot: [String]
    ) -> [String] {
        var ids = Set(effectiveWatchedIds(markedAt: markedAt, unmarkedAt: unmarkedAt))
        // Legacy membership survives only where NEITHER clock map has a record for the id: any stamp —
        // mark or unmark — from a clocked peer is more informed than a stamp-less set membership.
        for id in legacySnapshot
        where markedAt[id] == nil && unmarkedAt[id] == nil { ids.insert(id) }
        return ids.sorted()
    }
}
