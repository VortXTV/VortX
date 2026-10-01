import Foundation
import CoreFoundation

/// Pure, testable policy for the OWNER account library's per-title resume position rows
/// (`doc.vortx.library`, the exact shape `vortxSummary` emits / `refreshOwnerResumeCache` reads).
///
/// Why this exists (cross-device CW defect): the old emit loop let ANY engine row overwrite the prior
/// doc row's `t`/`d`/`v`, so a warm device whose engine still held an OLDER positive position could
/// clobber a NEWER remote playback written by a peer, and a bare re-add (engine row with no state at
/// all) silently DROPPED the doc row's `lastWatched` clock so the position could never be ordered again.
///
/// Rules (position fields `t`/`d`/`v`/`lastWatched` are ONE atomic unit — they always travel together):
///  - Both sides have a real clock: the NEWER `lastWatched` wins wholesale, so a newer rewind or an
///    explicit finish-0 propagates instead of being dragged back by a stale copy.
///  - A bare native metadata row can carry a constructor clock without any viewing state. That
///    clock is not playback evidence and cannot beat prior progress, even legacy clockless progress.
///  - Prior has a clock and the engine row has none (bare re-add / metadata refresh): the prior
///    position INCLUDING its clock survives, merged onto the engine's fresh name/poster/type. A bare
///    re-add can never manufacture a watch clock nor erase one.
///  - Engine has a clock and prior has none: the engine row wins (remote bare metadata cannot beat a
///    locally authored clock).
///  - Neither side has a clock: legacy path — caller keeps its existing guards (bare-re-add clobber
///    guard / Continue-Watching floor), which only engage when no clock can decide.
enum OwnerLibraryPositionPolicy {
    /// Parse a `lastWatched` value (ISO-8601 string, with or without fractional seconds, or a raw
    /// milliseconds number) into wall-clock ms. 0 = "no real clock" (missing / unparsable / epoch).
    static func lastWatchedMillis(_ raw: Any?) -> Double {
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
            return n.doubleValue.isFinite && n.doubleValue > 0 ? n.doubleValue : 0
        }
        if let i = raw as? Int { return Double(max(0, i)) }
        guard let s = raw as? String, !s.isEmpty else { return 0 }
        if let d = fractionalISO8601.date(from: s) ?? plainISO8601.date(from: s) {
            return d.timeIntervalSince1970 * 1000
        }
        return 0
    }

    /// True when the row carries a REAL causal clock (not a bare metadata re-add).
    static func hasRealClock(_ row: [String: Any]) -> Bool {
        hasPlaybackState(row) && lastWatchedMillis(row["lastWatched"]) > 0
    }

    /// A delayed/paged pull may contain a historical row. It cannot roll a cached causal
    /// observation backwards, and a clock-less legacy row cannot erase a real clock. Equal clocks
    /// are the same atomic observation and may refresh its representation.
    static func shouldReplaceCachedPosition(existingClock: Double, incomingClock: Double) -> Bool {
        existingClock <= 0 || incomingClock >= existingClock
    }

    /// A rail and its Play action must resolve the same causal observation, not choose different
    /// episodes merely because the engine happens to have a positive offset.
    static func preferCachedPosition(engineClock: Double, cachedClock: Double,
                                     playerActive: Bool, locallyRewound: Bool) -> Bool {
        !playerActive && !locallyRewound && cachedClock.isFinite && cachedClock > 0
            && cachedClock > engineClock
    }

    /// Resolve the position fields for one owner-library id. `engine` is this device's freshly emitted
    /// engine row; `prior` is the account doc's already-owned row. Pure: builds a new row, mutates nothing.
    /// The result always carries the engine's freshest display metadata (name/poster/type/id).
    static func resolve(engine: [String: Any], prior: [String: Any]) -> [String: Any] {
        let engineHasState = hasPlaybackState(engine)
        let engineClock = engineHasState ? lastWatchedMillis(engine["lastWatched"]) : 0
        let priorClock = hasPlaybackState(prior) ? lastWatchedMillis(prior["lastWatched"]) : 0
        // Prior position is provably newer (real clock, engine's missing or older): keep the prior
        // position + clock atomically; only refresh the display metadata from the engine row.
        if (!engineHasState && hasPlaybackState(prior)) || (priorClock > 0 && engineClock < priorClock) {
            // Preserve peer extensions as well as the atomic position; a native display refresh
            // does not have authority to erase cross-platform fields it does not emit.
            var merged = prior
            for key in ["id", "name", "type", "poster"] { merged[key] = engine[key] }
            // Position is one causal tuple. Do not substitute an engine d/v when the prior row
            // lacks it: that would fabricate a hybrid episode record.
            merged["t"] = prior["t"]
            merged["d"] = prior["d"]
            merged["v"] = prior["v"]
            merged["lastWatched"] = prior["lastWatched"]
            return merged
        }
        // Engine clock is newer or equal, or prior has no clock to defend: engine row wins as-is
        // (a newer rewind / finish-0 propagates; remote bare metadata cannot manufacture a clock).
        var resolved = engine
        if !engineHasState { resolved.removeValue(forKey: "lastWatched") }
        return resolved
    }

    /// AddToLibrary's constructor supplies a wall clock but no selected video, offset or duration.
    /// Real rewinds/finishes retain duration (and often video identity), so zero offsets still win.
    private static func hasPlaybackState(_ row: [String: Any]) -> Bool {
        if let video = row["v"] as? String, !video.isEmpty { return true }
        return ["t", "d"].contains { key in
            guard let number = row[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && number.doubleValue > 0
        }
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

}
