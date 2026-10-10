import SwiftUI

/// Immutable launch context for one series player's E+1 preparation. `videos` is deliberately a live
/// provider: a Continue Watching launch may mount before series metadata arrives, but the player can ask to
/// warm much later after the authoritative inventory has backfilled. This never dispatches `loadMeta`.
@MainActor
struct iOSNextEpisodePreparationContext {
    let seriesID: String
    let seriesName: String
    let defaultSeason: Int
    let defaultVideoID: String?
    let poster: String?
    let sources: [StreamSource]
    let legacyAddons: [AddonDescriptor]
    let continuity: String?
    let binge: String?
    let pin: ResolvedPin?
    let cachedHashes: Set<String>
    let signedInToVortX: Bool
    let videos: () -> [CoreVideo]
    let resumeOffset: (PlaybackMeta) async -> Double
    /// Owns profile/account/session fencing. It is checked before and after every await which could permit
    /// a stale profile's providers, credentials, or prepared transport to escape into the next player.
    let isCurrent: () -> Bool
}

/// Per-player owner of next-episode provider state. A Detail page owns one with `@StateObject`; a CW launch
/// constructs one inside its launch value. Consequently a stale/cancelled player cannot clear or reuse another
/// player's TorBox/Singularity/media-server publications.
@MainActor
final class iOSNextEpisodePreparer: ObservableObject {
    /// This scope is never shared between warm invocations. Cleanup can be immediate even when a
    /// non-cooperative resolver still holds the cancelled invocation across an await.
    @MainActor private final class AuxiliarySources {
        let torbox = TorBoxSearchSource()
        let sourceIndex = SourceIndexServeSource()
        let mediaServers = MediaServerSource()

        func clear() {
            torbox.clearResults()
            sourceIndex.clearResults()
            mediaServers.clearResults()
        }
    }

    private var attemptOwner = NextEpisodePreparationAttemptOwner()
    private var inFlight: (id: UUID, task: Task<PlayerEpisodeStream?, Never>, auxiliary: AuxiliarySources)?

    deinit { inFlight?.task.cancel() }

    func cancel() {
        inFlight?.task.cancel()
        inFlight?.auxiliary.clear()
        inFlight = nil
        attemptOwner.cancel()
    }

    func warm(_ request: NextEpisodePreparationRequest,
              context: iOSNextEpisodePreparationContext) async -> PlayerEpisodeStream? {
        guard !Task.isCancelled, context.isCurrent() else { return nil }
        // PlayerScreen already admits only one warm at a time. Do not coalesce by episode/retry: a new
        // invocation may carry a different source, remux generation or account even with the same key.
        inFlight?.task.cancel()
        inFlight?.auxiliary.clear()
        let attemptID = attemptOwner.begin()
        let auxiliary = AuxiliarySources()
        let task = Task<PlayerEpisodeStream?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.prepare(request, context: context, attemptID: attemptID, auxiliary: auxiliary)
        }
        inFlight = (attemptID, task, auxiliary)
        // Task is an owned child of this caller for cancellation purposes: PlayerScreen invalidation, cover
        // teardown, or replacement cancels the provider work immediately instead of merely abandoning an
        // unstructured task that continues to warm the old episode in the background.
        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
            Task { @MainActor in auxiliary.clear() }
        })
        guard attemptOwner.isCurrent(attemptID), !Task.isCancelled, context.isCurrent() else {
            if let lease = result?.torrentPreparationLease {
                retireWarmTorrentEngine(lease, reason: "superseded preparation caller")
            }
            result?.preparedRemux?.abandon(reason: "superseded preparation caller")
            if attemptOwner.finish(attemptID) { inFlight = nil }
            return nil
        }
        if attemptOwner.finish(attemptID) { inFlight = nil }
        return result
    }

    private func prepare(_ request: NextEpisodePreparationRequest,
                         context: iOSNextEpisodePreparationContext,
                         attemptID: UUID, auxiliary: AuxiliarySources) async -> PlayerEpisodeStream? {
        defer { auxiliary.clear() }
        guard !Task.isCancelled, attemptOwner.isCurrent(attemptID), context.isCurrent(),
              request.deadline > ProcessInfo.processInfo.systemUptime,
              let video = context.videos().first(where: { $0.id == request.episodeID }) else { return nil }
        let choice = SeriesSourceSticky.snapshot(for: context.seriesID)
        let sticky = choice.source
        let sourceOwner = EpisodeSourceOwner(legacySources: context.sources,
                                            legacyAddons: context.legacyAddons,
                                            legacyIsCurrent: context.isCurrent)
        func admitted() -> Bool {
            !Task.isCancelled && attemptOwner.isCurrent(attemptID)
                && sourceOwner.isCurrent && context.isCurrent() && SeriesSourceSticky.admits(choice)
        }
        guard admitted() else { return nil }
        // Publications belong to this invocation, including its deferred cancellation cleanup. A held
        // old attempt must never clear a successor that happens to target the same next episode.
        let torbox = auxiliary.torbox
        let sourceIndex = auxiliary.sourceIndex
        let mediaServers = auxiliary.mediaServers
        async let rawGroups = warmFetchEpisodeSourceGroups(providers: sourceOwner.providers(seriesID: context.seriesID, videoID: video.id), request: request,
                                                           wantedAddon: sticky.addon)
        let targetSeason = video.season ?? context.defaultSeason
        let targetEpisode = video.episode
        let roles = SourceIndexIdentity.Roles(catalogID: context.seriesID,
                                              defaultVideoID: context.defaultVideoID,
                                              currentVideoID: video.id, kind: .series)
        let titleID = SourceIndexIdentity.resolve(roles).titleID
        let target = SourceIndexIdentity.publicationTarget(roles, season: targetSeason, episode: targetEpisode)
        let mediaTarget = SourceIndexIdentity.mediaServerTarget(preferring: target, metaID: context.seriesID,
                                                                 videoID: video.id)
        AuxiliarySourcePipeline.refresh(target: target, torBox: torbox, sourceIndex: sourceIndex,
                                        isSignedIn: context.signedInToVortX)
        mediaServers.refresh(imdb: titleID, season: targetSeason, episode: targetEpisode,
                             title: context.seriesName, publicationTarget: mediaTarget)
        let auxiliary = await awaitAuxiliarySettlement(torbox: torbox, sourceIndex: sourceIndex,
                                                       mediaServers: mediaServers,
                                                       target: target, mediaTarget: mediaTarget,
                                                       deadline: min(request.deadline, ProcessInfo.processInfo.systemUptime + NextEpisodePreparationBudget.addonFetchBudget),
                                                       isCurrent: admitted)
        guard admitted() else { return nil }
        var groups = await rawGroups
        guard admitted() else { return nil }
        groups = TorBoxSearchSource.merge(authorizedBy: SourceIndexIdentity.mergeAuthorization(published: torbox.publishedTarget, page: target), auxiliary.torbox, into: groups)
        groups = SourceIndexServeSource.merge(authorizedBy: SourceIndexIdentity.mergeAuthorization(published: sourceIndex.publishedTarget, page: target), auxiliary.sourceIndex, into: groups)
        groups = MediaServerSource.merge(authorizedBy: SourceIndexIdentity.mediaServerMergeAuthorization(published: mediaServers.publishedTarget, page: mediaTarget), auxiliary.mediaServers, into: groups)
        let displayGroups = iOSDisplayGroups(groups)
        let candidates = StreamRanking.rankedCandidates(displayGroups, continuity: context.continuity,
            binge: context.binge, pin: context.pin, sticky: sticky, stickyAuthoritative: false,
            preserveChosenRelease: true, desiredAudioLanguage: choice.audioLanguage,
            providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) }, debridCachedHashes: context.cachedHashes)
            .filter { !StreamRanking.continuityLanguageMismatch($0, desired: choice.audioLanguage) }
        guard !candidates.isEmpty, admitted() else { return nil }
        let episodeHint = targetSeason >= 0 && (targetEpisode ?? -1) >= 0
            ? DebridEpisode(season: targetSeason, episode: targetEpisode ?? 0) : nil
        guard let selected = await iOSResolveRankedEpisodeCandidate(candidates, episode: episodeHint,
            waitForLocalUsenetNode: true, deadline: request.deadline, stillCurrent: admitted), admitted() else { return nil }
        let (best, url, ref) = (selected.stream, selected.url, selected.ref)
        let rawTorrent = ref == nil && best.url == nil
        var lease: PreparedTorrentEngineLease?
        var retainLease = false
        defer { if let lease, !retainLease { retireWarmTorrentEngine(lease, reason: "preparation did not retain winner") } }
        if rawTorrent {
            guard let prepared = await prepareWarmTorrentEngine(best, request: request) else { return nil }
            lease = prepared
            // Register cleanup BEFORE the stale fence. `prepareWarmTorrentEngine` has already retained the
            // engine by this point, so a profile/source switch here must retire it exactly once.
            guard admitted() else { return nil }
        }
        let signature = StreamRanking.signature(best)
        let dolbyVision = StreamRanking.isDolbyVision(signature)
        let remuxMode = VortXPreparedRemuxCallerPolicy.mode(avPlayerActive: request.prepareLocalAVPlayerRemux,
            mountIsOnDevice: request.prepareLocalAVPlayerRemux, rawTorrent: rawTorrent, dolbyVision: dolbyVision,
            dolbyVisionRemuxEligible: dolbyVision && PlayerEngineRouter.shouldDVRemux(url: url),
            plainRemuxEligible: !dolbyVision && PlayerEngineRouter.shouldPlainRemux(url: url))
        var mediaRequest = URLRequest(url: url)
        mediaRequest.setValue("bytes=0-8388607", forHTTPHeaderField: "Range")
        for (name, value) in best.requestHeaders ?? [:] where name.lowercased() != "range" { mediaRequest.setValue(value, forHTTPHeaderField: name) }
        mediaRequest.timeoutInterval = max(1, request.deadline - ProcessInfo.processInfo.systemUptime)
        let snapshot = mediaRequest
        let warm: BoundedRangeWarmup.Result?
        if VortXPreparedRemuxCallerPolicy.transportWarmPath(preparedMode: remuxMode) == .prefixRange {
            warm = await BoundedPreloadWorkPool.valueBeforeDeadline(request.deadline) { try? await BoundedRangeWarmup.fetch(snapshot, limit: 8 * 1_024 * 1_024) } ?? nil
        } else { warm = nil }
        guard admitted(), !(rawTorrent && warm == nil) else { return nil }
        let playbackMeta = PlaybackMeta(libraryId: context.seriesID, videoId: video.id, type: "series",
            name: context.seriesName, poster: video.thumbnail ?? context.poster, season: video.season, episode: video.episode)
        let resume = await BoundedPreloadWorkPool.valueBeforeDeadline(request.deadline) { await context.resumeOffset(playbackMeta) } ?? 0
        guard admitted() else { return nil }
        var attachment: VortXPreparedRemuxAttachment?
        if let remuxMode {
            let owner = VortXPreparedRemuxOwnerIdentity(mediaID: playbackMeta.videoId,
                generation: request.preparedRemuxGeneration, sourceSignature: signature)
            if let handle = await AVPlayerEngineController.prepareRemuxTransport(input: url, headers: best.requestHeaders,
                mode: remuxMode, startAtSeconds: resume, ownerIdentity: owner) {
                attachment = VortXPreparedRemuxAttachment(handle: handle, ownerIdentity: owner)
                // As above, construct/register the owned attachment before checking staleness. Otherwise a
                // successful handle returned after a profile switch is silently discarded without abandon.
                guard admitted() else {
                    attachment?.abandon(reason: "iOS preparation stale after remux readiness")
                    attachment = nil
                    return nil
                }
            }
        }
        guard admitted() else { attachment?.abandon(reason: "iOS preparation cancelled after transport readiness"); return nil }
        retainLease = true
        return PlayerEpisodeStream(stream: best, url: url, meta: playbackMeta,
            title: "\(context.seriesName)  ·  S\(video.season ?? context.defaultSeason)E\(video.episodeNumber)",
            resume: resume, debridRef: ref, engineAddonBase: iOSEngineAddonBase(for: best, in: displayGroups),
            preparationRequest: request, torrentPreparationLease: lease, preparedRemux: attachment)
    }

    private struct AuxiliarySnapshot {
        let torbox: [CoreStream]; let sourceIndex: [CoreStream]; let mediaServers: [CoreStreamSourceGroup]
    }
    private func awaitAuxiliarySettlement(torbox: TorBoxSearchSource, sourceIndex: SourceIndexServeSource,
        mediaServers: MediaServerSource, target: SourceIndexIdentity.TargetResolution,
        mediaTarget: SourceIndexIdentity.MediaServerTarget?, deadline: TimeInterval,
        isCurrent: () -> Bool) async -> AuxiliarySnapshot {
        while !Task.isCancelled && isCurrent() {
            let settled = SourceSettlementPolicy.decide(raw: .terminal, auxiliary: [
                torbox.settlementState(for: target), sourceIndex.settlementState(for: target),
                mediaServers.settlementState(for: mediaTarget)], deadlineExpired: ProcessInfo.processInfo.systemUptime >= deadline)
            if settled.isSettled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return AuxiliarySnapshot(
            torbox: SourceIndexIdentity.mergeAuthorization(published: torbox.publishedTarget, page: target) != nil ? torbox.streams : [],
            sourceIndex: SourceIndexIdentity.mergeAuthorization(published: sourceIndex.publishedTarget, page: target) != nil ? sourceIndex.streams : [],
            mediaServers: SourceIndexIdentity.mediaServerMergeAuthorization(published: mediaServers.publishedTarget, page: mediaTarget) != nil ? mediaServers.groups : [])
    }
}
