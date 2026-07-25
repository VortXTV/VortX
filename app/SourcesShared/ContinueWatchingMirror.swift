import Foundation

// MARK: - "Mirror Continue Watching from Stremio": the gate + the pure floor decisions
//
// This file wires the third member of the mirror family. `MirrorSettings.mirrorAddons` gates whether VortX
// pushes add-on removals back to a connected Stremio account (CoreBridge.uninstallAddon / refreshAddons) and
// `MirrorSettings.mirrorLibrary` gates FLOOR-vs-MIRROR for the owner LIBRARY MEMBERSHIP set
// (VortXSyncManager.vortxSummary). `MirrorSettings.mirrorContinueWatching` is the same contract applied to the
// owner's RESUME POSITIONS, which is the payload the library entries carry as `t` / `d` / `v`.
//
// WHY THE POSITION AND NOT THE MEMBERSHIP. stremio-core has ONE library bucket and ONE ingestion action for it
// (`SyncLibraryWithAPI`), which pulls a Stremio account's membership AND its per-item `state.timeOffset` in the
// same reconcile; the engine's `continue_watching_preview` is then derived from that bucket (membership is
// purely `time_offset > 0`). There is no engine action that pulls membership without progress, so the CW toggle
// cannot be honestly implemented by gating ingestion: gating `SyncLibraryWithAPI` would silently also control
// the library, which is `mirrorLibrary`'s job. The only seam where Stremio-sourced progress is separable from
// VortX-owned progress is where the engine's position meets the VortX-owned position, which is what this file
// decides. VortX's own position is the account-doc truth: `doc.vortx.library` t/d/v, cached locally in
// `OwnerResumeStore` and re-hydrated on every device.
//
// THE CONTRACT, matching the family doc on `MirrorSettings`:
//
//   OFF (the default) = FLOOR. VortX owns Continue Watching. A Stremio-sourced position may SEED a title VortX
//   holds no position for, but it may never drag an existing VortX position BACKWARDS and it may never zero
//   one. So a stale Stremio copy, a title finished on an official Stremio client, or a Stremio rewind cannot
//   roll back or empty the VortX rail, on this device or on any other device through the account doc.
//
//   ON = EXACT MIRROR. The engine position (which reflects the live Stremio set after a reconcile) is
//   authoritative and REPLACES the VortX-owned one, so a Stremio rewind / finish / rollback propagates.
//
// INERT WITHOUT A LIVE STREMIO SESSION, WHICH IS WHAT KEEPS THE DEFAULT SAFE. The engine's library bucket
// carries BOTH this device's own playback progress and a Stremio pull, so a floor is only correct while
// Stremio can actually be the author of a change. With no live session (`CoreBridge.isLoggedIn() == false`:
// the imported-away default, every VortX-only install, and every signed-out device)
// `stremioMayReplaceContinueWatching` returns true and every decision below is EXACTLY today's behaviour.
// That is why shipping this with the existing default OFF changes nothing for a user who is not connected to
// Stremio, and fixes the rollback only for the users the toggle is actually about.

extension MirrorSettings {

    /// One saved Continue Watching position. `t` / `d` are in WHOLE SECONDS (the `doc.vortx.library` unit, not
    /// the engine's milliseconds) and `v` is the resume video id: an episode id for a series, nil for a movie.
    struct CWPosition: Equatable {
        var t: Double
        var d: Double
        var v: String?

        /// An empty `v` (how the account doc spells "no episode") normalizes to nil, so a doc-sourced position
        /// and an engine-sourced one compare on the same footing.
        init(t: Double, d: Double, v: String? = nil) {
            self.t = t
            self.d = d
            self.v = (v?.isEmpty == false) ? v : nil
        }
    }

    /// Whether a connected Stremio account's Continue Watching may REPLACE VortX's own saved position.
    ///
    /// True (mirror) when the toggle is ON, and ALWAYS true when no Stremio session is live: with no session
    /// the engine's positions are purely VortX's own (local playback plus doc hydration), so there is nothing
    /// to floor and the caller must keep today's behaviour untouched.
    static func stremioMayReplaceContinueWatching(stremioSessionLive: Bool, mirrorOn: Bool) -> Bool {
        !stremioSessionLive || mirrorOn
    }

    /// Live-toggle convenience. `stremioSessionLive` is `CoreBridge.isLoggedIn()`, a live STREMIO session
    /// (`ctx.profile.auth`), not the VortX account.
    static func stremioMayReplaceContinueWatching(stremioSessionLive: Bool) -> Bool {
        stremioMayReplaceContinueWatching(stremioSessionLive: stremioSessionLive,
                                          mirrorOn: mirrorContinueWatching)
    }

    /// The position that survives when an engine-held position meets the VortX-owned one.
    ///
    /// - `engine`: what stremio-core's library bucket currently holds for the title. Under a live Stremio
    ///   session this may have been authored by an official Stremio client rather than by VortX.
    /// - `owned`: VortX's own position for the same title (`doc.vortx.library` / `OwnerResumeStore`), nil when
    ///   VortX has never held one.
    /// - `mayReplace`: `stremioMayReplaceContinueWatching(...)`.
    /// - `locallyRewound`: this device zeroed the title itself, through `CoreBridge.finishedWatching`
    ///   (`LocalRewindLog`). A genuine finish looks exactly like a rollback from the outside (t drops to 0),
    ///   so without this flag the floor would pin finished titles in the rail forever.
    ///
    /// Order matters: every early return below is an "engine wins" case, so the floor only ever engages on the
    /// narrow situation it exists for, a live Stremio session moving an existing VortX position backwards.
    static func resolveContinueWatching(engine: CWPosition,
                                        owned: CWPosition?,
                                        mayReplace: Bool,
                                        locallyRewound: Bool) -> CWPosition {
        // MIRROR mode, or no live Stremio session: today's behaviour, engine authoritative.
        if mayReplace { return engine }
        // VortX owns nothing resumable for this title, so a Stremio position SEEDS it (the FLOOR contract:
        // adds are always welcome, only removals and rollbacks are refused).
        guard let owned, owned.t > 0 else { return engine }
        // This device produced the zero itself: a real finish must still propagate under the floor.
        if locallyRewound { return engine }
        // Different videos are different positions, not a rollback. For a series both ids usually carry
        // `<titleId>:<season>:<episode>`, so an ORDERED comparison is possible and a Stremio roll BACK to an
        // earlier episode is refused; when either id is unparseable the two are not comparable and the engine
        // wins (refusing an uncomparable change would freeze a series on one episode forever).
        if engine.v != owned.v {
            guard let engineEpisode = episodeOrdinal(engine.v), let ownedEpisode = episodeOrdinal(owned.v) else {
                return engine
            }
            return engineEpisode < ownedEpisode ? merged(keeping: owned, filledFrom: engine) : engine
        }
        // Same video: forward progress (including any local play, which always moves t forward) wins; a move
        // BACKWARDS, and the t == 0 that a Stremio-side finish produces, is refused.
        return engine.t >= owned.t ? engine : merged(keeping: owned, filledFrom: engine)
    }

    /// The VortX-owned position wins, but a duration it is missing is filled from the engine's fresher copy so
    /// the rail can still compute a progress bar. Position and video id are never taken from the engine here.
    private static func merged(keeping owned: CWPosition, filledFrom engine: CWPosition) -> CWPosition {
        CWPosition(t: owned.t, d: owned.d > 0 ? owned.d : engine.d, v: owned.v)
    }

    /// `(season, episode)` read off a Stremio video id of the shape `<titleId>:<season>:<episode>`. Nil for a
    /// movie id or any other shape, which callers treat as "not comparable".
    static func episodeOrdinal(_ videoID: String?) -> EpisodeOrdinal? {
        guard let videoID, !videoID.isEmpty else { return nil }
        let parts = videoID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let episode = Int(parts[parts.count - 1]),
              let season = Int(parts[parts.count - 2]) else { return nil }
        return EpisodeOrdinal(season: season, episode: episode)
    }

    /// Comparable season/episode pair. Season dominates, so S02E01 is later than S01E20.
    struct EpisodeOrdinal: Comparable, Equatable {
        let season: Int
        let episode: Int
        static func < (lhs: EpisodeOrdinal, rhs: EpisodeOrdinal) -> Bool {
            lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
        }
    }
}

/// Library ids this device rewound to zero ITSELF, held until the account doc confirms the zero.
///
/// The Continue Watching FLOOR refuses a position that moves backwards, and a genuine finish is
/// indistinguishable from a rollback by value alone (t drops to 0). `CoreBridge.finishedWatching` is the SINGLE
/// `RewindLibraryItem` dispatch site in the app, so stamping there captures every local rewind and nothing else.
///
/// SELF-CLEARING, so this can never grow or pin a stale exemption: `vortxSummary` forgets an id as soon as the
/// pulled account doc already carries `t == 0` for it, which is exactly "the finish has landed on the account".
/// `finishedWatching` kicks an immediate `pushThisDevice()`, so that normally happens on the very next summary.
/// A stamp that somehow never clears is harmless: it only ever restores the pre-toggle behaviour for one title.
enum LocalRewindLog {
    private static let key = "vortx.cw.localRewinds.v1"

    /// Hard bound, in the shape `AddonTombstones` uses for its durable sets. The log is normally near-empty
    /// (an id lives here only between a local finish and the account doc absorbing its zero), so the cap is
    /// only a floor under a pathological device that somehow never pushes: the OLDEST stamps are dropped, and
    /// dropping one only costs that title the exemption, which restores the pre-toggle behaviour for it.
    private static let maxEntries = 500

    /// All ids currently stamped. Read fresh from UserDefaults so the write side (`CoreBridge.finishedWatching`)
    /// and the retire side (`VortXSyncManager.vortxSummary`) always see the same authority.
    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func stamp(_ id: String) {
        guard !id.isEmpty else { return }
        var ids = all()
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > maxEntries { ids.removeFirst(ids.count - maxEntries) }
        UserDefaults.standard.set(ids, forKey: key)
    }

    static func contains(_ id: String) -> Bool {
        guard !id.isEmpty, let ids = UserDefaults.standard.stringArray(forKey: key) else { return false }
        return ids.contains(id)
    }

    static func forget(_ id: String) {
        guard !id.isEmpty, var ids = UserDefaults.standard.stringArray(forKey: key) else { return }
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        UserDefaults.standard.set(ids, forKey: key)
    }
}
