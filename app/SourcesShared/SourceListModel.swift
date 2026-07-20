import Foundation
import Combine

/// Owns a detail screen's ENTIRE source-list pipeline off the SwiftUI render path:
/// snapshot -> merge (TorBox search + Singularity) -> tombstone subtraction -> direct-links filter ->
/// StreamRanking, all coalesced and run OFF the main thread, publishing ONE immutable ranked result
/// per real change.
///
/// WHY: the detail bodies used to re-assemble the whole list inside `body` (streamGroups rebuild +
/// two merges + an O(N) signature string over every stream) on EVERY CoreBridge @Published bump, and
/// `revision` bumps 6-7x/sec while sources load. On a 1200+ stream title that saturated the main
/// thread (Mac force-quit, dead keyboard nav, beachball; the earlier DetailRankMemo cached only the
/// rank and deliberately left the assembly outside). This model inverts the flow:
///
///  1. O(1) EPOCH SIGNATURE: a tuple of monotonic epochs (CoreBridge.streamsEpoch, which bumps only
///     when the coalescer saw the ready-stream set really change, plus the TorBox / Singularity
///     source epochs) and one Hasher fold of the small ranking inputs. Comparing signatures is a few
///     Int compares, zero allocation, instead of joining a string over 1256 streams.
///  2. 250 ms TRAILING COALESCER: a Combine throttle (latest: true) over the epoch publishers, so a
///     burst of engine events during source loading produces at most ~4 rebuilds/sec and the LAST
///     event of a burst always lands. It subscribes to the specific publishers, never to
///     CoreBridge.objectWillChange.
///  3. OFF-MAIN ASSEMBLY, PUBLISH ONCE: on a coalesced signature change it snapshots the immutable
///     inputs on the main actor, hops to a detached task for merge + tombstone subtraction + rank
///     (StreamRanking is pure and lock-protected), and publishes ONE `[CoreStreamSourceGroup]` (+
///     `best`) back on the main actor. A generation counter discards a stale completion superseded
///     mid-flight. Steady-state main-thread cost for the UI is an Equatable array check.
///
/// One instance per detail screen (`@StateObject`). The source-list section consumes ONLY
/// `groups` / `best`; it must not derive the list from CoreBridge inside `body` anymore.
@MainActor
final class SourceListModel: ObservableObject, SourceIndexLifecycleParticipant {

    // MARK: Published output (the ONLY thing the source-list UI observes)

    /// The assembled, filtered, ranked source groups, ready to render. Replaced atomically per rebuild,
    /// so an unchanged list is the SAME array instance and `==` on it is a buffer-identity fast path.
    @Published private(set) var groups: [CoreStreamSourceGroup] = []
    /// The ranked best playable stream (continuity-aware), the Watch-Now pick.
    @Published private(set) var best: CoreStream?
    /// Resolution-tier labels present in the ranked list (["4K","1080p",...]); the Quality picker's first level.
    /// Computed once per off-main rebuild so the detail bodies stop re-ranking on every body eval.
    @Published private(set) var tiers: [String] = []
    /// Best playable stream per resolution label (forward-compat: the player's resolution dropdown).
    /// Computed alongside `tiers` on the same off-main pass.
    @Published private(set) var resolutionOptions: [(label: String, stream: CoreStream)] = []

    // MARK: Context (the view-owned ranking inputs, set from body, equality-guarded)

    /// The small per-screen inputs the assembly needs from the view. Set via `setContext` from `body`
    /// (cheap: a handful of strings and flags); an unchanged context is a no-op, a changed one nudges
    /// the coalescer. Never published, so setting it from body cannot re-enter the render.
    struct Context: Equatable {
        var metaId = ""              // for the pin scope + the health-metric log only
        var streamId: String?        // nil = all loaded groups (movie/live); set = one episode's groups (iOS + tvOS episode pages)
        var continuity: String?      // remembered quality signature for the best() pick (nil for live)
        var pin: ResolvedPin?        // resolved pinned source, from the view's SourcePinStore lookup
        var prefsSignature = ""      // SourcePreferences.rankingSignature (filter/rank settings)
        var isKids = false           // Kids content guard state (read inside applyUserFilters)
        var directLinksOnly = false  // drop torrent sources entirely
        var disabledAddons: Set<String> = []   // per-profile disabled add-on bases
    }

    // MARK: Internals

    /// O(1) rebuild signature: epochs + one hash. Equal signature = the published output is already
    /// correct, skip the whole assembly.
    private struct Signature: Equatable {
        let streamsEpoch: Int
        let torboxEpoch: Int
        let singularityEpoch: Int
        let mediaServerEpoch: Int
        let inputsHash: Int
    }

    /// Sendable weak indirection for the detached worker's main-actor publish. Capturing `weak self` directly
    /// and then closing over that mutable weak capture inside `MainActor.run` is rejected in Swift 6 mode.
    private final class WeakOwner: @unchecked Sendable {
        weak var value: SourceListModel?
        init(_ value: SourceListModel) { self.value = value }
    }

    private weak var core: CoreBridge?
    private weak var torbox: TorBoxSearchSource?
    private weak var singularity: SourceIndexServeSource?
    private weak var mediaServers: MediaServerSource?
    private weak var debridCache: DebridCacheAwareness?

    private var context = Context()
    private var subscriptions: Set<AnyCancellable> = []
    private let trigger = PassthroughSubject<Void, Never>()
    private var generation = 0
    private var publishedSignature: Signature?
    private var pendingSignature: Signature?

    /// The coalescing window. At most ~4 rebuilds/sec while an engine burst streams sources in; the
    /// `[sing] merged` log below fires once per rebuild, so >4 lines/sec on a loading title means
    /// this coalescer is broken (the log's frequency is the health metric).
    private static let coalesceMs = 250

    /// Wire the model to its per-screen sources and start the coalesced rebuild pipeline. Idempotent:
    /// a re-appear just nudges a refresh. Subscribes to the SPECIFIC epoch/content publishers (never
    /// CoreBridge.objectWillChange, whose revision storm is exactly what this model exists to absorb).
    func bind(core: CoreBridge, torbox: TorBoxSearchSource,
              singularity: SourceIndexServeSource, mediaServers: MediaServerSource,
              debridCache: DebridCacheAwareness) {
        SourceIndexLifecycleScope.shared.register(self)
        guard subscriptions.isEmpty else {
            trigger.send()
            return
        }
        self.core = core
        self.torbox = torbox
        self.singularity = singularity
        self.mediaServers = mediaServers
        self.debridCache = debridCache

        let events: [AnyPublisher<Void, Never>] = [
            core.$streamsEpoch.map { _ in () }.eraseToAnyPublisher(),      // ready-stream set really changed
            core.$addons.map { _ in () }.eraseToAnyPublisher(),            // add-on installed/removed (tombstones)
            torbox.$streams.map { _ in () }.eraseToAnyPublisher(),         // TorBox search results replaced
            singularity.$streams.map { _ in () }.eraseToAnyPublisher(),    // Singularity pool results replaced
            mediaServers.$groups.map { _ in () }.eraseToAnyPublisher(),    // media-server direct-play groups replaced
            debridCache.$cachedHashes.map { _ in () }.eraseToAnyPublisher(), // cache awareness re-ranks
            trigger.eraseToAnyPublisher(),                                 // context change / manual nudge
        ]
        Publishers.MergeMany(events)
            .throttle(for: .milliseconds(Self.coalesceMs), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &subscriptions)
        // Paint immediately on first bind (back-navigation can arrive with streams already resident).
        rebuild()
    }

    /// Update the view-owned ranking inputs. Safe (and intended) to call from `body`: it is a few
    /// cheap reads plus an equality check, publishes nothing synchronously, and only nudges the
    /// coalescer when an input actually moved.
    func setContext(metaId: String, streamId: String?, continuity: String?, pin: ResolvedPin?) {
        var next = Context()
        next.metaId = metaId
        next.streamId = streamId
        next.continuity = continuity
        next.pin = pin
        next.prefsSignature = SourcePreferences.shared.rankingSignature
        next.isKids = ProfileStore.activeIsKids()
        next.directLinksOnly = PlaybackSettings.directLinksOnly
        next.disabledAddons = ProfileStore.activeDisabledAddons()
        guard next != context else { return }
        context = next
        trigger.send()
    }

    // MARK: Rebuild (coalesced entry; snapshot on main, assemble off-main, publish once)

    private func rebuild() {
        guard let core, let torbox, let singularity, let mediaServers, let debridCache else { return }
        let ctx = context
        let tombstones = AddonTombstones.all()
        let cachedHashes = debridCache.cachedHashes

        // O(1)-ish signature: three epochs + one fold of the small inputs. No per-stream work.
        var hasher = Hasher()
        hasher.combine(ctx.metaId)
        hasher.combine(ctx.streamId)
        hasher.combine(ctx.continuity)
        hasher.combine(String(describing: ctx.pin))
        hasher.combine(ctx.prefsSignature)
        hasher.combine(ctx.isKids)
        hasher.combine(ctx.directLinksOnly)
        hasher.combine(ctx.disabledAddons)
        hasher.combine(cachedHashes)
        hasher.combine(tombstones)
        let signature = Signature(streamsEpoch: core.streamsEpoch,
                                  torboxEpoch: torbox.epoch,
                                  singularityEpoch: singularity.epoch,
                                  mediaServerEpoch: mediaServers.epoch,
                                  inputsHash: hasher.finalize())
        guard signature != publishedSignature, signature != pendingSignature else { return }
        pendingSignature = signature
        generation &+= 1
        let gen = generation

        // Immutable snapshot on the main actor; everything below is value types.
        let raw = ctx.streamId.map { core.streamGroups(forStreamId: $0) } ?? core.streamGroups()
        let torboxStreams = torbox.streams
        let singularityStreams = singularity.streams
        let singularityEpoch = singularity.epoch
        let sourceLifecycle = SourceIndexLifecycleClock.snapshot()
        let includedSingularity = !singularityStreams.isEmpty
        let mediaServerGroups = mediaServers.groups
        // Freeze the ranking prefs HERE, on the main actor. StreamRanking reads SourcePreferences live at
        // score/filter time; its excludeRegex/includeRegex refs + @Published flags are reassigned on the
        // main thread (Settings edits, profile reload()), so reading them from the detached rank below
        // would race. The snapshot is installed as a task-local INSIDE the detached task (Task.detached
        // does not inherit task-locals), so the off-main rank reads this frozen copy, never the singleton.
        let prefsSnapshot = SourcePreferences.shared.snapshot()
        let owner = WeakOwner(self)

        Task.detached(priority: .userInitiated) {
            // STEP 3 (delete fix), belt and suspenders: CoreBridge.streamGroups() already subtracts
            // tombstoned add-ons at the streams layer; re-filtering the snapshot here keeps the model
            // correct even for a caller that fed it un-subtracted groups.
            var assembled = raw
            if !tombstones.isEmpty {
                assembled = assembled.filter { !tombstones.contains(AddonTombstones.normalize($0.id)) }
            }
            // Merge order preserved from the old per-body displayGroups: TorBox search first, then the
            // Singularity pool, then the media-server direct-play groups, then the direct-links filter so a
            // merged torrent obeys the same rule. Final rank order is decided by StreamRanking, not merge order.
            assembled = MediaServerSource.merge(mediaServerGroups,
                          into: SourceIndexServeSource.merge(singularityStreams,
                                  into: TorBoxSearchSource.merge(torboxStreams, into: assembled)))
            if ctx.directLinksOnly {
                assembled = assembled.compactMap { group in
                    let streams = group.streams.filter { !$0.isTorrent }
                    guard !streams.isEmpty else { return nil }
                    return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
                }
            }
            // Run the rank against the frozen prefs snapshot (task-local), so StreamRanking never reads the
            // mutable SourcePreferences singleton across threads. withValue binds it for this synchronous
            // scope only; existing main-actor StreamRanking callers install nothing and read the live singleton.
            let (ranked, rankedBest, rankedTiers, rankedResOpts) =
                SourcePreferences.$readingOverride.withValue(prefsSnapshot) {
                    let groups = StreamRanking.rankedGroups(assembled, pin: ctx.pin, debridCachedHashes: cachedHashes)
                    let best = StreamRanking.best(groups, continuity: ctx.continuity, pin: ctx.pin,
                                                  debridCachedHashes: cachedHashes)
                    return (groups, best, StreamRanking.tiers(groups), StreamRanking.resolutionOptions(groups))
                }
            let streamCount = ranked.reduce(0) { $0 + $1.streams.count }

            await MainActor.run {
                guard let self = owner.value else { return }
                // A newer rebuild superseded this one mid-flight: discard the stale result.
                guard gen == self.generation else { return }
                guard singularity.permitsDetachedPublish(
                    sourceEpoch: singularityEpoch,
                    lifecycle: sourceLifecycle,
                    includedSingularity: includedSingularity
                ) else {
                    self.pendingSignature = nil
                    self.trigger.send()
                    return
                }
                self.pendingSignature = nil
                self.publishedSignature = signature
                // HEALTH METRIC: one line per rebuild. More than ~4/sec on a loading title means the
                // 250 ms coalescer is broken (this used to fire per body eval, thousands of lines).
                VXProbe.log("sing", "merged rebuild meta=\(ctx.metaId.isEmpty ? "-" : ctx.metaId) groups=\(ranked.count) streams=\(streamCount) torbox=\(torboxStreams.count) singularity=\(singularityStreams.count) gen=\(gen)")
                self.groups = ranked
                self.best = rankedBest
                self.tiers = rankedTiers
                self.resolutionOptions = rankedResOpts
            }

            // Phase 7 SHADOW (flag `vortxShadowRanking`, default OFF): rank the SAME assembled
            // inputs through the vortx-core engine and log any ordering divergence vs the Swift
            // rank published above. Pure observation, run strictly AFTER the live publish: flag
            // OFF is a single boolean read, flag ON spawns its own detached utility task, and in
            // neither case can it touch `groups`/`best` or delay this rebuild.
            VortxShadowRanking.observe(groups: assembled, continuity: ctx.continuity, pin: ctx.pin,
                                       cachedHashes: cachedHashes, prefs: prefsSnapshot,
                                       metaId: ctx.metaId)
        }
    }

    /// A Source Index gate closure must make every pooled row unselectable before the throttled rebuild can run.
    /// Blank all derived choices, invalidate detached work and signatures, then request a clean ordinary-source
    /// snapshot. The rebuild may repopulate non-Singularity groups while the Source Index gate stays closed.
    func sourceIndexLifecycleDidClose(retiredSourceGeneration _: UInt64) {
        generation &+= 1
        pendingSignature = nil
        publishedSignature = nil
        groups = []
        best = nil
        tiers = []
        resolutionOptions = []
        trigger.send()
    }
}
