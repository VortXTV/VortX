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
    @Published private var publishedGroups: [CoreStreamSourceGroup] = []
    /// The ranked best playable stream (continuity-aware), the Watch-Now pick.
    @Published private var publishedBest: CoreStream?
    /// Resolution-tier labels present in the ranked list (["4K","1080p",...]); the Quality picker's first level.
    /// Computed once per off-main rebuild so the detail bodies stop re-ranking on every body eval.
    @Published private var publishedTiers: [String] = []
    /// Best playable stream per resolution label (forward-compat: the player's resolution dropdown).
    /// Computed alongside `tiers` on the same off-main pass.
    @Published private var publishedResolutionOptions: [(label: String, stream: CoreStream)] = []
    /// Published in the same main-actor transaction as the ranked rows it describes. Auto-pick reads this
    /// receipt instead of independently polling one subset of contributors.
    @Published private var publishedSettlement: SourceSettlementDecision = .waiting

    var groups: [CoreStreamSourceGroup] {
        publishedIdentity == outputIdentity(for: context) ? publishedGroups : []
    }
    var best: CoreStream? {
        publishedIdentity == outputIdentity(for: context) ? publishedBest : nil
    }
    var tiers: [String] {
        publishedIdentity == outputIdentity(for: context) ? publishedTiers : []
    }
    var resolutionOptions: [(label: String, stream: CoreStream)] {
        publishedIdentity == outputIdentity(for: context) ? publishedResolutionOptions : []
    }
    var settlement: SourceSettlementDecision {
        publishedIdentity == outputIdentity(for: context) ? publishedSettlement : .waiting
    }
    var isSettled: Bool { settlement.isSettled }

    // MARK: Context (the view-owned ranking inputs, set from body, equality-guarded)

    /// The small per-screen inputs the assembly needs from the view. Set via `setContext` from `body`
    /// (cheap: a handful of strings and flags); an unchanged context is a no-op, a changed one nudges
    /// the coalescer. Never published, so setting it from body cannot re-enter the render.
    struct Context: Equatable {
        var metaId = ""              // for the pin scope + the health-metric log only
        var streamId: String?        // nil = all loaded groups (movie/live); set = one episode's groups (iOS + tvOS episode pages)
        var auxiliaryTarget: SourceIndexIdentity.TargetResolution = .absent
        var mediaServerTarget: SourceIndexIdentity.MediaServerTarget?
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
        let torboxSettlementEpoch: Int
        let singularitySettlementEpoch: Int
        let mediaServerSettlementEpoch: Int
        let jsProviderEpoch: Int
        let jsProviderSettlementEpoch: Int
        let settlementDeadlineExpired: Bool
        let inputsHash: Int
    }

    private struct OutputIdentity: Equatable {
        let metaId: String
        let streamId: String?
        let auxiliaryContentToken: String?
        let mediaServerTargetToken: String?
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
    /// Optional community JS provider source. Nil at every existing call site (the feature ships dark behind
    /// its OFF-by-default gate), so its epochs fold in as 0 and its merge is a pure pass-through until a screen
    /// opts in by passing one to `bind`.
    private weak var jsProvider: JSProviderSource?

    private var context = Context()
    private var subscriptions: Set<AnyCancellable> = []
    private let trigger = PassthroughSubject<Void, Never>()
    private var generation = 0

    /// A stable per-instance discriminator for the shared health log ONLY. When two SourceListModel instances
    /// exist for one title (a detail page re-created while the old one is still tearing down), their
    /// per-instance `generation` counters, each monotonic on its own, interleave in the single log with nothing
    /// to tell them apart, which reads as the counter "going backward". This tags each rebuild line so the two
    /// streams separate. Assigned once at init from a main-actor counter; never load-bearing.
    private static var instanceSeq = 0
    private let instanceID: Int = { SourceListModel.instanceSeq += 1; return SourceListModel.instanceSeq }()
    private var publishedSignature: Signature?
    private var publishedIdentity: OutputIdentity?
    private var pendingSignature: Signature?
    private var settlementDeadlineExpired = false
    private var settlementDeadlineTask: Task<Void, Never>?
    private let settlementMaximumWait: TimeInterval

    init(settlementMaximumWait: TimeInterval = SourceSettlementPolicy.maximumWait) {
        self.settlementMaximumWait = max(0, settlementMaximumWait)
    }

    /// The coalescing window. At most ~4 rebuilds/sec while an engine burst streams sources in; the
    /// `[sing] merged` log below fires once per rebuild, so >4 lines/sec on a loading title means
    /// this coalescer is broken (the log's frequency is the health metric).
    private static let coalesceMs = 250

    /// Wire the model to its per-screen sources and start the coalesced rebuild pipeline. Idempotent:
    /// a re-appear just nudges a refresh. Subscribes to the SPECIFIC epoch/content publishers (never
    /// CoreBridge.objectWillChange, whose revision storm is exactly what this model exists to absorb).
    func bind(core: CoreBridge, torbox: TorBoxSearchSource,
              singularity: SourceIndexServeSource, mediaServers: MediaServerSource,
              debridCache: DebridCacheAwareness,
              jsProvider: JSProviderSource? = nil) {
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
        self.jsProvider = jsProvider

        var events: [AnyPublisher<Void, Never>] = [
            core.$streamsEpoch.map { _ in () }.eraseToAnyPublisher(),      // ready-stream set really changed
            core.$addons.map { _ in () }.eraseToAnyPublisher(),            // add-on installed/removed (tombstones)
            torbox.$streams.map { _ in () }.eraseToAnyPublisher(),         // TorBox search results replaced
            torbox.$settlementEpoch.map { _ in () }.eraseToAnyPublisher(), // including empty/error terminal result
            singularity.$streams.map { _ in () }.eraseToAnyPublisher(),    // Singularity pool results replaced
            singularity.$settlementEpoch.map { _ in () }.eraseToAnyPublisher(),
            mediaServers.$groups.map { _ in () }.eraseToAnyPublisher(),    // media-server direct-play groups replaced
            mediaServers.$settlementEpoch.map { _ in () }.eraseToAnyPublisher(),
            debridCache.$cachedHashes.map { _ in () }.eraseToAnyPublisher(), // cache awareness re-ranks
            trigger.eraseToAnyPublisher(),                                 // context change / manual nudge
        ]
        if let jsProvider {
            events.append(jsProvider.$groups.map { _ in () }.eraseToAnyPublisher())         // JS provider groups replaced
            events.append(jsProvider.$settlementEpoch.map { _ in () }.eraseToAnyPublisher()) // including empty/error terminal
        }
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
    func setContext(
        metaId: String,
        streamId: String?,
        continuity: String?,
        pin: ResolvedPin?,
        auxiliaryTarget: SourceIndexIdentity.TargetResolution,
        mediaServerTarget: SourceIndexIdentity.MediaServerTarget?
    ) {
        var next = Context()
        next.metaId = metaId
        next.streamId = streamId
        next.auxiliaryTarget = auxiliaryTarget
        next.mediaServerTarget = mediaServerTarget
        next.continuity = continuity
        next.pin = pin
        next.prefsSignature = SourcePreferences.shared.rankingSignature
        next.isKids = ProfileStore.activeIsKids()
        next.directLinksOnly = PlaybackSettings.directLinksOnly
        next.disabledAddons = ProfileStore.activeDisabledAddons()
        guard next != context else { return }
        let identityChanged = next.metaId != context.metaId || next.streamId != context.streamId
            || next.auxiliaryTarget != context.auxiliaryTarget
            || next.mediaServerTarget != context.mediaServerTarget
        context = next
        if identityChanged {
            // A detached rebuild for the prior title/episode may still be running. Retire its generation and
            // synchronously remove every selectable output before asking the coalescer for the new identity.
            // Without this fence, one render after E2 -> E3 can still expose E2's rows and Watch-Now pick.
            generation &+= 1
            pendingSignature = nil
            publishedSignature = nil
            publishedSettlement = .waiting
            resetSettlementDeadline(for: outputIdentity(for: next))
        }
        trigger.send()
    }

    /// Repaint the list back to its loading ("Finding sources...") state for a SAME-id re-find. `setContext`
    /// only re-arms the deadline and blanks the settled receipt on an IDENTITY change (a new title/episode);
    /// a "Re-find sources" tap keeps the identity, so without this the section would keep showing the stale
    /// settled rows while the fresh add-on re-query is in flight. Retire the published signature (so the
    /// coalesced rebuild runs again even if nothing else moved), blank the settlement receipt, and re-arm the
    /// settlement deadline for the CURRENT identity. The engine's Unload -> Load then empties and refills the
    /// ranked rows through the normal `streamsEpoch` path.
    func beginRefresh() {
        generation &+= 1
        pendingSignature = nil
        publishedSignature = nil
        publishedSettlement = .waiting
        resetSettlementDeadline(for: outputIdentity(for: context))
        trigger.send()
    }

    private func resetSettlementDeadline(for identity: OutputIdentity) {
        settlementDeadlineTask?.cancel()
        settlementDeadlineExpired = false
        let maximumWait = settlementMaximumWait
        settlementDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(maximumWait))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.outputIdentity(for: self.context) == identity else { return }
            self.settlementDeadlineTask = nil
            self.settlementDeadlineExpired = true
            self.trigger.send()
        }
    }

    private func outputIdentity(for context: Context) -> OutputIdentity {
        OutputIdentity(
            metaId: context.metaId,
            streamId: context.streamId,
            auxiliaryContentToken: SourceIndexIdentity.validatedTarget(context.auxiliaryTarget)?.contentID,
            mediaServerTargetToken: context.mediaServerTarget?.token
        )
    }

    // MARK: Rebuild (coalesced entry; snapshot on main, assemble off-main, publish once)

    private func rebuild() {
        guard let core, let torbox, let singularity, let mediaServers, let debridCache else { return }
        let ctx = context
        let tombstones = AddonTombstones.all()
        let cachedHashes = debridCache.cachedHashes

        // The remembered manual pick + the just-failed-provider demotion, snapshotted HERE on the main actor
        // (diag-21). `SeriesSourceSticky.preference` reads main-actor state and so cannot be called from the
        // detached rank below, and without these two terms this list ranked by up to `stickyWeight` (6000)
        // differently from the player and the preload, which DO apply them: the row the list showed first was
        // then not the one Watch-Now played. Same discipline as `prefsSnapshot` further down.
        //
        // Keyed on `metaId` - the show id, exactly what `pin` is scoped to - and only for an EPISODIC context
        // (`streamId != nil`), the same gate the tvOS detail page uses to scope its groups. Nothing writes a
        // sticky record for a non-series key (the player gates its write on `type == "series"`), so a
        // franchise/collection page routed through the same lane simply reads nil.
        let sticky: (addon: String?, bingeGroup: String?)? = ctx.streamId != nil && !ctx.metaId.isEmpty
            ? SeriesSourceSticky.preference(for: ctx.metaId)
            : nil
        // Capture-free and lock-guarded inside, so it is safe to call from the detached rank.
        let providerPenalty: @Sendable (String) -> Bool = { ProviderHealth.penaltyActive(addonName: $0) }

        // O(1)-ish signature: three epochs + one fold of the small inputs. No per-stream work.
        var hasher = Hasher()
        hasher.combine(ctx.metaId)
        hasher.combine(ctx.streamId)
        hasher.combine(ctx.auxiliaryTarget)
        hasher.combine(ctx.mediaServerTarget)
        hasher.combine(ctx.continuity)
        hasher.combine(String(describing: ctx.pin))
        hasher.combine(ctx.prefsSignature)
        hasher.combine(ctx.isKids)
        hasher.combine(ctx.directLinksOnly)
        hasher.combine(ctx.disabledAddons)
        hasher.combine(cachedHashes)
        hasher.combine(tombstones)
        // A pick made in the player changes the rank without changing any epoch, so it has to be in the
        // signature or the list would keep serving the pre-pick order until something else moved.
        hasher.combine(sticky?.addon)
        hasher.combine(sticky?.bingeGroup)
        let signature = Signature(streamsEpoch: core.streamsEpoch,
                                  torboxEpoch: torbox.epoch,
                                  singularityEpoch: singularity.epoch,
                                  mediaServerEpoch: mediaServers.epoch,
                                  torboxSettlementEpoch: torbox.settlementEpoch,
                                  singularitySettlementEpoch: singularity.settlementEpoch,
                                  mediaServerSettlementEpoch: mediaServers.settlementEpoch,
                                  jsProviderEpoch: jsProvider?.epoch ?? 0,
                                  jsProviderSettlementEpoch: jsProvider?.settlementEpoch ?? 0,
                                  settlementDeadlineExpired: settlementDeadlineExpired,
                                  inputsHash: hasher.finalize())
        guard signature != publishedSignature, signature != pendingSignature else { return }
        pendingSignature = signature
        generation &+= 1
        let gen = generation

        // Immutable snapshot on the main actor; everything below is value types.
        let raw = ctx.streamId.map { core.streamGroups(forStreamId: $0) } ?? core.streamGroups()
        let target = ctx.auxiliaryTarget
        let torboxAuthorization = SourceIndexIdentity.mergeAuthorization(
            published: torbox.publishedTarget,
            page: target
        )
        let singularityAuthorization = SourceIndexIdentity.mergeAuthorization(
            published: singularity.publishedTarget,
            page: target
        )
        let torboxStreams = torboxAuthorization == nil ? [] : torbox.streams
        let singularityStreams = singularityAuthorization == nil ? [] : singularity.streams
        let singularityEpoch = singularity.epoch
        let sourceLifecycle = SourceIndexLifecycleClock.snapshot()
        let includedSingularity = !singularityStreams.isEmpty
        let mediaTarget = ctx.mediaServerTarget
        let mediaAuthorization = SourceIndexIdentity.mediaServerMergeAuthorization(
            published: mediaServers.publishedTarget,
            page: mediaTarget
        )
        let mediaServerGroups = mediaAuthorization == nil ? [] : mediaServers.groups
        // Community JS providers: same IMDb-target authorization as TorBox, published per-provider groups like
        // the media-server lane. Nil source (feature dark / screen didn't opt in) => empty, pass-through merge.
        let jsProviderAuthorization = jsProvider.flatMap {
            SourceIndexIdentity.mergeAuthorization(published: $0.publishedTarget, page: target)
        }
        let jsProviderGroups = jsProviderAuthorization == nil ? [] : (jsProvider?.groups ?? [])
        let rawProgress = ctx.streamId.map { core.streamLoadProgress(forStreamId: $0) }
            ?? core.streamLoadProgress()
        let rawSettlement = core.streamContributorSettlement(metaId: ctx.metaId, streamId: ctx.streamId)
        let auxiliarySettlement = [
            torbox.settlementState(for: target),
            singularity.settlementState(for: target),
            mediaServers.settlementState(for: mediaTarget),
            jsProvider?.settlementState(for: target) ?? .inactive,
        ]
        let hasPendingContributor = ([rawSettlement] + auxiliarySettlement).contains(.pending)
        if SourceSettlementPolicy.shouldRearmDeadline(
            previous: publishedSettlement,
            hasPendingContributor: hasPendingContributor,
            deadlineTaskActive: settlementDeadlineTask != nil
        ) {
            // A contributor may retry for the SAME title after an empty/error terminal result. The prior
            // settled-all receipt canceled its deadline, so this new generation needs a fresh bounded owner;
            // otherwise a hung retry would leave auto-pick waiting forever.
            pendingSignature = nil
            publishedSettlement = .waiting
            resetSettlementDeadline(for: outputIdentity(for: ctx))
            trigger.send()
            return
        }
        let settlement = SourceSettlementPolicy.decide(
            raw: rawSettlement,
            auxiliary: auxiliarySettlement,
            deadlineExpired: settlementDeadlineExpired
        )
        // Freeze the ranking prefs HERE, on the main actor. StreamRanking reads SourcePreferences live at
        // score/filter time; its excludeRegex/includeRegex refs + @Published flags are reassigned on the
        // main thread (Settings edits, profile reload()), so reading them from the detached rank below
        // would race. The snapshot is installed as a task-local INSIDE the detached task (Task.detached
        // does not inherit task-locals), so the off-main rank reads this frozen copy, never the singleton.
        let prefsSnapshot = SourcePreferences.shared.snapshot()
        let owner = WeakOwner(self)
        let metaToken = VXProbeRedaction.identityToken(ctx.metaId.isEmpty ? nil : ctx.metaId)

        Task.detached(priority: .userInitiated) {
            // STEP 3 (delete fix), belt and suspenders: CoreBridge.streamGroups() already subtracts
            // tombstoned add-ons at the streams layer; re-filtering the snapshot here keeps the model
            // correct even for a caller that fed it un-subtracted groups.
            var assembled = raw
            if !tombstones.isEmpty {
                assembled = assembled.filter { !tombstones.contains(AddonTombstones.normalize($0.id)) }
            }
            // Merge order preserved from the old per-body displayGroups: TorBox search first, then the
            // Singularity pool, then the media-server direct-play groups, then the community JS provider groups,
            // then the direct-links filter so a merged torrent obeys the same rule. Final rank order is decided
            // by StreamRanking, not merge order.
            assembled = JSProviderSource.merge(
                authorizedBy: jsProviderAuthorization,
                jsProviderGroups,
                into: MediaServerSource.merge(
                    authorizedBy: mediaAuthorization,
                    mediaServerGroups,
                    into: SourceIndexServeSource.merge(
                        authorizedBy: singularityAuthorization,
                        singularityStreams,
                        into: TorBoxSearchSource.merge(
                            authorizedBy: torboxAuthorization,
                            torboxStreams,
                            into: assembled
                        )
                    )
                )
            )
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
                                                  sticky: sticky, stickyAuthoritative: false,
                                                  providerPenalty: providerPenalty,
                                                  debridCachedHashes: cachedHashes)
                    return (groups, best, StreamRanking.tiers(groups), StreamRanking.resolutionOptions(groups))
                }
            let streamCount = ranked.reduce(0) { $0 + $1.streams.count }

            await MainActor.run {
                guard let self = owner.value else { return }
                // A newer rebuild superseded this one mid-flight: discard the stale result.
                guard gen == self.generation else { return }
                // A contributor can finish or retry while detached ranking is running. Never attach a
                // complete receipt to a rank built from a different contributor generation.
                guard core.streamsEpoch == signature.streamsEpoch,
                      torbox.epoch == signature.torboxEpoch,
                      singularity.epoch == signature.singularityEpoch,
                      mediaServers.epoch == signature.mediaServerEpoch,
                      torbox.settlementEpoch == signature.torboxSettlementEpoch,
                      singularity.settlementEpoch == signature.singularitySettlementEpoch,
                      mediaServers.settlementEpoch == signature.mediaServerSettlementEpoch,
                      (self.jsProvider?.epoch ?? 0) == signature.jsProviderEpoch,
                      (self.jsProvider?.settlementEpoch ?? 0) == signature.jsProviderSettlementEpoch,
                      self.settlementDeadlineExpired == signature.settlementDeadlineExpired else {
                    self.pendingSignature = nil
                    self.trigger.send()
                    return
                }
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
                self.publishedIdentity = self.outputIdentity(for: ctx)
                // HEALTH METRIC: one line per rebuild. More than ~4/sec on a loading title means the
                // 250 ms coalescer is broken (this used to fire per body eval, thousands of lines).
                VXProbe.log("sing", "merged rebuild inst=\(self.instanceID) meta=\(metaToken) groups=\(ranked.count) streams=\(streamCount) torbox=\(torboxStreams.count) singularity=\(singularityStreams.count) gen=\(gen)")
                self.publishedGroups = ranked
                self.publishedBest = rankedBest
                self.publishedTiers = rankedTiers
                self.publishedResolutionOptions = rankedResOpts
                if self.publishedSettlement != settlement {
                    let pending = auxiliarySettlement.filter { $0 == .pending }.count
                    VXProbe.log(
                        "sources",
                        "settlement meta=\(metaToken) decision=\(String(describing: settlement)) raw=\(rawProgress.loaded)/\(rawProgress.total) auxiliaryPending=\(pending) gen=\(gen)"
                    )
                }
                self.publishedSettlement = settlement
                if settlement == .settledAll {
                    self.settlementDeadlineTask?.cancel()
                    self.settlementDeadlineTask = nil
                }
            }

            // Phase 7 SHADOW (flag `vortxShadowRanking`, default OFF): rank the SAME assembled
            // inputs through the vortx-core engine and log any ordering divergence vs the Swift
            // rank published above. Pure observation, run strictly AFTER the live publish: flag
            // OFF is a single boolean read, flag ON spawns its own detached utility task, and in
            // neither case can it touch `groups`/`best` or delay this rebuild.
            VortxShadowRanking.observe(groups: assembled, continuity: ctx.continuity, pin: ctx.pin,
                                       cachedHashes: cachedHashes, prefs: prefsSnapshot,
                                       metaId: metaToken)
        }
    }

    /// A Source Index gate closure must make every pooled row unselectable before the throttled rebuild can run.
    /// Blank all derived choices, invalidate detached work and signatures, then request a clean ordinary-source
    /// snapshot. The rebuild may repopulate non-Singularity groups while the Source Index gate stays closed.
    func sourceIndexLifecycleDidClose(retiredSourceGeneration _: UInt64) {
        generation &+= 1
        pendingSignature = nil
        publishedSignature = nil
        publishedIdentity = nil
        publishedGroups = []
        publishedBest = nil
        publishedTiers = []
        publishedResolutionOptions = []
        publishedSettlement = .waiting
        trigger.send()
    }
}
