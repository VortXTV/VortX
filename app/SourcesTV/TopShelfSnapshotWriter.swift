import Foundation
import TVServices

/// Publishes the Apple TV **Top Shelf** snapshot from the live Continue Watching state.
///
/// This is the app-side half of the hand-off; `SourcesShared/TopShelfSnapshot.swift` is the wire
/// contract, and the `VortXTopShelf` extension is the reader. This file is tvOS-app only and is NOT
/// compiled into the extension, which is what keeps the extension free of the engine models.
///
/// WHY IT LIVES HERE, at the Home model layer: the shelf mirrors the SAME profile-aware Continue
/// Watching array Home renders (`profiles.activeUsesEngineHistory ? core.continueWatching :
/// profiles.cwItems`), so it is published from the points that already recompute Home. It reads the
/// shared singletons directly, so a call site is a bare `publishCurrent()` and the profile-aware
/// selection rule is written down ONCE, here. Nothing in the watched / sync file set is touched.
enum TopShelfSnapshotWriter {

    /// User setting: mirror Continue Watching onto the tvOS Home screen's Top Shelf.
    ///
    /// Opt-OUT (default on) because the shelf is the feature. It is worth a switch at all because the
    /// Top Shelf is visible to anyone who wakes the TV, without opening VortX and without passing the
    /// profile picker, so what you are part-way through is on show in the room. Someone who does not
    /// want that needs a way to say so.
    static let showKey = "vortx.topShelf.showContinueWatching"
    static let showDefault = true

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: showKey) as? Bool ?? showDefault
    }

    /// Rebuild and publish the shelf from the CURRENT engine + profile state.
    ///
    /// Main-actor because it reads `@Published` state off `CoreBridge` / `ProfileStore`. Cheap and
    /// idempotent: it caps at 8 items, and the store's own content diff means an unchanged Home
    /// refresh writes nothing and wakes nothing. Safe to call from every Home re-seed.
    @MainActor
    static func publishCurrent() {
        // Setting OFF publishes an EMPTY shelf rather than skipping the write. The snapshot outlives
        // the process, so merely not refreshing would leave the last row sitting on the Home screen:
        // the exact thing the user just asked us to stop showing.
        guard isEnabled else { publish([]); return }

        let profiles = ProfileStore.shared
        // The SAME rule Home renders by: the owner profile rides the account's engine history, an
        // overlay profile rides its own private synced history. Without this an overlay profile's
        // shelf would show the owner's titles.
        let cw = profiles.activeUsesEngineHistory ? CoreBridge.shared.continueWatching : profiles.cwItems
        publish(items(from: cw))
    }

    /// Clear the shelf. Used when the shell can no longer vouch for what the shelf would say.
    @MainActor
    static func clear() { publish([]) }

    // MARK: Mapping

    /// Flatten the engine's Continue Watching into the wire items.
    static func items(from cw: [CoreCWItem]) -> [TopShelfSnapshot.Item] {
        cw.lazy
            // The rail's own prune rule. `CoreBridge` already applies `isFinished` before publishing
            // the rail, but the shelf re-applies it rather than trusting that, because a shelf is
            // rendered from a FILE that can outlive the process that wrote it: a title finished on
            // another device and synced down must not linger on the TV's Home screen.
            .filter { !$0.isFinished }
            // Removed / temp entries are not "in the library" (see CoreCWItem), so they have no
            // business on the Home screen even while the engine still carries them in the bucket.
            .filter { $0.removed != true && $0.temp != true }
            .prefix(TopShelfSnapshot.maxItems)
            .map {
                TopShelfSnapshot.Item(
                    id: $0.id,
                    type: $0.type,
                    title: $0.name,
                    poster: shelfPoster($0.poster),
                    progress: shelfProgress($0.progress)
                )
            }
    }

    /// Watch progress, guaranteed finite and inside 0…1.
    ///
    /// `CoreCWItem.progress` already clamps, so in practice this is a pass-through. It exists because
    /// a non-finite value here would be silently CORROSIVE rather than merely wrong: JSONEncoder throws
    /// on a NaN or an infinity by default, so a single bad item would fail the whole encode, the write
    /// would return false, and the shelf would quietly freeze on its last good content forever with
    /// nothing in the log to say why. The engine feeds `progress` from add-on-supplied durations, which
    /// is not a source worth betting a silent permanent failure on for the cost of one comparison.
    /// `TVTopShelfSectionedItem.playbackProgress` documents the same 0…1 requirement on the far side.
    private static func shelfProgress(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// The poster URL to hand the system.
    ///
    /// This is the RAW add-on / metahub poster, deliberately NOT routed through our own
    /// `poster.vortx.tv` baked-art service, for two independent reasons:
    ///
    ///  1. The system fetches Top Shelf art itself, out of process, on its own schedule, with no
    ///     chance for us to attach headers. Our art edge is behind the `X-VX-*` signing gate, so a
    ///     header-signed URL is not an option here (that is what `PosterImageLoader` does, and it
    ///     works only because the fetch is ours).
    ///  2. The header-less variant (`VortXEdgeAuth.signedURL`) bakes a per-second `vts` that the
    ///     workers accept only within a 300s skew window. A snapshot routinely sits on disk for hours
    ///     or days between writes, and the shelf is rendered when the app is NOT running, so nothing
    ///     can re-sign it. Every signed URL we could write would be expired long before the system
    ///     asked for it, and the shelf would be permanently art-less the moment the edge leaves
    ///     OBSERVE mode. A raw poster is un-gated, needs no headers, and does not expire.
    ///
    /// Returns nil for a non-http(s) URL. An item with no art still renders (title + progress), so a
    /// missing poster costs a tile's picture, never the row.
    private static func shelfPoster(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return raw
    }

    // MARK: Publish

    @MainActor
    private static func publish(_ items: [TopShelfSnapshot.Item]) {
        // No container => unsigned build / no App Group / Lite. Nothing to do, nothing to log loudly.
        guard TopShelfSnapshot.containerURL != nil else { return }
        let changed = TopShelfSnapshot.write(items)
        guard changed else { return }
        // Only nudge the system when the content actually moved: this wakes the extension, so firing
        // it on every unchanged Home re-seed would be pure churn.
        TVTopShelfContentProvider.topShelfContentDidChange()
        DiagnosticsLog.log("topshelf", "published \(items.count) item(s)")
    }
}
