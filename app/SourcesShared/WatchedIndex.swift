import Foundation
import Combine

/// App-wide watched-title lookup for catalog covers (#111): answers "has the ACTIVE profile watched
/// this title?" for the Home rails and category grids, whose items are catalog previews
/// (CoreMeta / MetaPreview), not library items, so they carry no watched state of their own.
///
/// Sources, honoring the per-profile history invariant (the exact split LibraryView.isWatched uses):
///  - OWNER profile (`activeUsesEngineHistory`): the ENGINE's own watched bookkeeping,
///    `LibraryItem.state.timesWatched > 0` (upstream `LibraryItem::watched()`), read from the
///    engine's persisted library buckets (`library_recent.json` / `library.json` in
///    `CoreBridge.storageDirURL`, the same directory `start()` hands the engine; the env writes
///    them temp-then-rename, so a read never sees a torn file). A bucket is consumed ONLY when its
///    `uid` matches the live ctx uid (`CoreBridge.currentUID()`), mirroring the engine's own
///    `LibraryBucket::merge_bucket` uid refusal, so a stale bucket from a previous account can
///    never badge covers for the new one. The buckets cover the WHOLE library plus the temporary
///    watched-from-catalog markers, not just the page the Library tab has loaded. The live
///    published `library` / `continueWatching` models are unioned in so a fresh mark shows
///    without waiting for the engine's async bucket persist.
///  - OVERLAY profile: only that profile's private overlay (`ProfileStore.watch` entries with a
///    non-empty `watchedVideoIds`), NEVER the account/engine set.
///
/// READ-ONLY by design: this never writes engine or profile state. A title with no watch data is
/// simply absent from the set, so its cover shows no badge.
///
/// Perf shape: one `Set<String>` published on the main queue; rails read `ids.contains(item.id)`
/// per cell (O(1), no engine dispatch, no per-cell work). Rebuilds are event-driven (library / ctx /
/// profile changes), throttled to at most ~2 per second, and skipped entirely while a player is up
/// (no rail is visible then; the player-dismiss flip triggers a catch-up rebuild). The bucket JSON
/// parse runs on a utility queue; a trailing resweep ~2s later catches the engine's bucket persist,
/// which is an async effect that can land AFTER the NewState emit the first pass reacted to.
final class WatchedIndex: ObservableObject {
    static let shared = WatchedIndex()

    /// Meta ids the ACTIVE profile has watched. Published on the main queue only.
    @Published private(set) var ids: Set<String> = []

    private var subscriptions: Set<AnyCancellable> = []
    /// Bumped per rebuild so a stale off-main bucket parse can never publish over a newer pass
    /// (e.g. one scheduled just before a profile switch).
    private var generation = 0

    /// Series ids the ACTIVE profile has fully watched by its AIRED, REGULAR-SEASON episodes (issue #143),
    /// derived by the detail views (the only place with a series' full video list AND the watched set) and
    /// unioned into `ids`. This flips the poster cover badge for a series whose episodes were MARKED rather
    /// than played, whose engine `LibraryItem.times_watched` stays 0 (a per-episode / per-season mark
    /// updates only the WatchedBitField). Purely in-memory and read-only; never written to engine / profile
    /// / disk. Cleared on a profile switch (see `rebuild`) so it never leaks across profiles.
    private var derivedSeriesWatched: Set<String> = []
    /// Last published BASE set (engine buckets ∪ live ∪ Trakt/SIMKL shadows, or the overlay set), kept so
    /// `noteSeriesWatched` can republish `base ∪ derivedSeriesWatched` without a full rebuild, preserving
    /// the `ids = base ∪ derived` invariant.
    private var lastBase: Set<String> = []
    /// The profile the derived set was computed for; a change clears it in `rebuild`.
    private var lastActiveProfile: UUID?

    /// Engine model fields whose change can move watched state: `ctx` carries the library bucket
    /// (every mark / unmark / sync lands there), `library` and `continue_watching_preview` re-emit
    /// on marks and progress saves and back the instant in-memory union.
    private static let relevantFields: Set<String> = ["ctx", "library", "continue_watching_preview"]
    /// How long after a rebuild the resweep re-reads the buckets (see class doc).
    private static let resweepDelay: TimeInterval = 2

    private init() {
        let core = CoreBridge.shared
        let profiles = ProfileStore.shared
        let events: [AnyPublisher<Void, Never>] = [
            // Engine changes. changedFields is assigned on main immediately before the revision
            // bump (same block), so reading it in this filter observes the matching set.
            core.$revision
                .filter { _ in !CoreBridge.shared.changedFields.isDisjoint(with: Self.relevantFields) }
                .map { _ in () }.eraseToAnyPublisher(),
            // Player dismissed: catch up on everything skipped while it was up.
            core.$playerActive.filter { !$0 }.map { _ in () }.eraseToAnyPublisher(),
            // Profile switch swaps the source (engine bookkeeping vs private overlay).
            profiles.$activeID.map { _ in () }.eraseToAnyPublisher(),
            // Overlay marks / progress flip live.
            profiles.$watch.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(events)
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &subscriptions)
        DispatchQueue.main.async { [weak self] in self?.rebuild() }   // seed from the hydrated buckets
    }

    /// Recompute the watched set for the active profile. Main queue only (the throttle scheduler
    /// guarantees it for event-driven calls).
    private func rebuild() {
        // No rail is visible during playback; the ~20s engine progress saves would otherwise
        // re-parse the buckets for nothing. The $playerActive(false) event above catches up.
        guard !CoreBridge.shared.playerActive else { return }
        // A profile switch swaps the whole watched source; the derived series-completion set (issue #143)
        // was computed for the OUTGOING profile, so drop it before this profile's pass so a badge never
        // leaks across profiles. Its detail view re-feeds the new profile's completion on next open.
        let currentProfile = ProfileStore.shared.activeID
        if currentProfile != lastActiveProfile {
            lastActiveProfile = currentProfile
            derivedSeriesWatched.removeAll()
        }
        generation &+= 1
        let gen = generation
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: its private overlay only. A whole-title mark records the metaId
            // itself, episode finishes record episode ids; either way non-empty means watched.
            let overlay = Set(ProfileStore.shared.watch.filter { !$0.value.watchedVideoIds.isEmpty }.keys)
            publish(overlay, ifCurrent: gen)
            return
        }
        // Owner profile. Live union base first: whatever engine state is already published in
        // memory, so a fresh mark badges immediately even before the bucket persist lands.
        var live = Set<String>()
        for item in CoreBridge.shared.library?.catalog ?? [] where item.isWatched { live.insert(item.id) }
        for item in CoreBridge.shared.continueWatching where item.isWatched { live.insert(item.id) }
        // Capture the account identity NOW, on main, alongside the live state: the bucket reads
        // below only honor files stamped with this uid (see bucketWatchedIDs). An account switch
        // in the window before the resweep re-triggers rebuild via ctx events, and the generation
        // guard drops these passes' publishes.
        let expectedUID = CoreBridge.shared.currentUID()
        // External watched shadows (additive-read, each opt-in behind its OWN import toggle): union the ids
        // watched on Trakt AND completed on SIMKL into the badge set. Each shadow holds BOTH identity forms
        // per title (imdb `tt…` and `tmdb:<id>`), so a cover keyed by either identity matches the plain
        // `ids.contains(item.id)` read below (issue #143). Each returns empty when its own import toggle is
        // off. Kick each one's throttled refresh so a stale cache re-pulls; a pull calls back into
        // `externalShadowChanged` (one more rebuild) when it changes something. NEVER an engine write.
        TraktSyncEngine.shared.refreshIfStale()
        SIMKLWatchedShadow.shared.refreshIfStale()
        let shadow = TraktSyncEngine.shared.shadowWatchedIDs()
            .union(SIMKLWatchedShadow.shared.shadowWatchedIDs())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let first = Self.bucketWatchedIDs(expectedUID: expectedUID)
            DispatchQueue.main.async { self?.publish(live.union(first).union(shadow), ifCurrent: gen) }
            // Resweep: the engine persists the bucket as an async effect AFTER the NewState emit,
            // so the first pass can read the pre-mark file. One trailing re-read settles it.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.resweepDelay) { [weak self] in
                let second = Self.bucketWatchedIDs(expectedUID: expectedUID)
                DispatchQueue.main.async { self?.publish(live.union(second).union(shadow), ifCurrent: gen) }
            }
        }
    }

    /// The Trakt shadow cache changed (a fresh pull, or the import toggle flipped): rebuild so the unioned
    /// badge set reflects it without waiting for an engine event. Main-queue safe; the rebuild throttle
    /// already coalesces bursts.
    func externalShadowChanged() { rebuild() }

    /// A detail view computed whether a SERIES is fully watched by its aired, regular-season episodes
    /// (issue #143). Union it into the badge set (read-only, in-memory) so the poster cover flips even when
    /// the engine's library `times_watched` stays 0 for a series whose episodes were marked rather than
    /// played, and un-badge it when the show drops back below complete. Main-queue only (SwiftUI callers).
    /// Never writes engine / profile / disk state.
    func noteSeriesWatched(_ metaId: String, isFullyWatched: Bool) {
        let contained = derivedSeriesWatched.contains(metaId)
        guard isFullyWatched != contained else { return }
        if isFullyWatched { derivedSeriesWatched.insert(metaId) } else { derivedSeriesWatched.remove(metaId) }
        let merged = lastBase.union(derivedSeriesWatched)
        if merged != ids { ids = merged }
    }

    /// Publish on main, dropping stale generations and no-op sets (identical set republishes nothing,
    /// so rails do not re-evaluate on the routine resweep). Always records the base and unions the derived
    /// series-completion set so `ids = base ∪ derivedSeriesWatched` holds after every pass.
    private func publish(_ next: Set<String>, ifCurrent gen: Int) {
        guard gen == generation else { return }
        lastBase = next
        let merged = next.union(derivedSeriesWatched)
        guard merged != ids else { return }
        ids = merged
    }

    /// Ids with `state.timesWatched > 0` across BOTH persisted engine buckets (the recent split and
    /// the rest), read from `CoreBridge.storageDirURL` (the single source of truth for the engine's
    /// storage dir; never re-derive the path). Removed-but-watched entries stay in: the user did
    /// watch them. Read-only; any missing / unreadable file contributes nothing (fail-soft, never
    /// a crash).
    ///
    /// UID GATE: a bucket persists `{ uid, items }`, where `uid` is the auth user id (null when
    /// signed out), and the engine itself refuses to merge a bucket whose uid mismatches
    /// (`LibraryBucket::merge_bucket`). Mirror that: after an owner signs into a DIFFERENT account,
    /// the on-disk bucket can still hold the previous account's entries for a window, so a file
    /// whose uid does not match `expectedUID` is skipped entirely (degrades to no badges from that
    /// file, the same fail-soft posture as missing/corrupt).
    private static func bucketWatchedIDs(expectedUID: String?) -> Set<String> {
        var found = Set<String>()
        let dir = CoreBridge.storageDirURL
        for name in ["library_recent.json", "library.json"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = root["items"] as? [String: Any] else { continue }
            // Absent / null uid decodes to nil and matches only the signed-out state (nil uid),
            // exactly the engine's own equality semantics.
            guard (root["uid"] as? String) == expectedUID else { continue }
            for (id, value) in items {
                guard let item = value as? [String: Any],
                      let state = item["state"] as? [String: Any] else { continue }
                if (state["timesWatched"] as? Int ?? 0) > 0 { found.insert(id) }
            }
        }
        return found
    }
}
