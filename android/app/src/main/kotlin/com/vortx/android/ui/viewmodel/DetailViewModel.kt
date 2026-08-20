package com.vortx.android.ui.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.debrid.DebridService
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.engine.SourceListModel
import com.vortx.android.engine.StreamRanking
import com.vortx.android.integrations.buildMediaRef
import com.vortx.android.library.WatchlistStore
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.model.AuthState
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef
import com.vortx.android.model.MediaType
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.model.orderedBySeasonEpisode
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.player.PlaybackBehaviorSettings
import com.vortx.android.player.PlayerSourceSwitchCommitGate
import com.vortx.android.player.PlayerSourceSwitchResolution
import com.vortx.android.singularity.SourceIndexServeSource
import com.vortx.android.trailer.TrailerCoordinator
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sources.ResolvedPin
import com.vortx.android.sources.CanonicalContentIdentity
import com.vortx.android.sources.ProviderHealth
import com.vortx.android.sources.SeriesSourceSticky
import com.vortx.android.sources.SourceRequestFence
import com.vortx.android.sources.SourcePinContext
import com.vortx.android.sources.SourcePinScope
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.torbox.TorBoxSearchSource
import com.vortx.android.ui.UiState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal data class EpisodeSwitchSelectionLease(
    val request: SourceRequestFence.Token,
    val targetEpisodeId: String,
    val previousEpisodeId: String?,
    val previousSeason: Int?,
) {
    fun rollbackIfOwned(
        currentRequest: SourceRequestFence.Token?,
        selectedEpisodeId: String?,
        restore: (episodeId: String?, season: Int?) -> Unit,
    ): Boolean {
        if (currentRequest != request || selectedEpisodeId != targetEpisodeId) return false
        restore(previousEpisodeId, previousSeason)
        return true
    }
}

internal suspend fun <T> withEpisodeSwitchCancellationRollback(
    rollbackIfOwned: () -> Unit,
    block: suspend () -> T,
): T = try {
    block()
} catch (cancelled: CancellationException) {
    rollbackIfOwned()
    throw cancelled
}

internal fun MetaDetail.episodeForResolve(selectedEpisodeId: String?): Episode? =
    videos.firstOrNull { it.id == selectedEpisodeId }

internal fun Episode.debridEpisodeForResolve(): DebridResolver.Episode? {
    if (season < 0 || episode <= 0) return null
    return DebridResolver.Episode(season, episode)
}

internal data class DebridCacheEvidence(
    val owner: DebridOwnerToken,
    val credentialRevision: Long,
    val torrentServices: Map<String, DebridService>,
    val usenetUrls: Set<String>,
) {
    val hashes: Set<String> get() = torrentServices.keys
}

internal fun torrentServicesFromCacheHits(
    hits: Map<String, DebridCoordinator.CacheHit>,
): Map<String, DebridService> =
    hits.entries.associate { (hash, hit) -> hash.trim().lowercase() to hit.service }

internal fun DebridCacheEvidence?.forOwner(
    owner: DebridOwnerToken?,
    credentialRevision: Long,
): DebridCacheEvidence? =
    this?.takeIf {
        owner != null && it.owner == owner && it.credentialRevision == credentialRevision
    }

internal fun currentAssembledBest(
    state: com.vortx.android.engine.SourceListState,
    request: SourceRequestFence.Token?,
): StreamSource? = state.best.takeIf {
    request != null &&
        state.requestGeneration == request.generation &&
        state.streamId == request.targetId
}

internal fun bestSourceForCurrentRequest(
    state: com.vortx.android.engine.SourceListState,
    request: SourceRequestFence.Token?,
    currentGroups: List<StreamGroup>,
    rankCurrent: (List<StreamGroup>) -> StreamSource?,
): StreamSource? = currentAssembledBest(state, request) ?: rankCurrent(currentGroups)

/// Map one ranked stream into the failover candidate that carries both its source identity and, for torrents,
/// the exact provider whose account cache check confirmed the hash. Usenet deliberately carries no torrent
/// provider because its resolve path remains TorBox-only.
internal fun debridCandidateFor(
    source: StreamSource,
    torrentServices: Map<String, DebridService> = emptyMap(),
): DebridCoordinator.DebridCandidate? {
    if (source.url != null) return null
    return when {
        source.isUsenet -> DebridCoordinator.DebridCandidate(
            nzbUrl = source.nzbUrl,
            usenetKnownHash = source.usenetKnownHash,
            fileMustInclude = source.fileMustInclude,
            fileIdx = source.fileIdx,
            source = source,
        )
        !source.infoHash.isNullOrEmpty() -> {
            val hash = source.infoHash.trim().lowercase()
            DebridCoordinator.DebridCandidate(
                infoHash = source.infoHash,
                fileIdx = source.fileIdx,
                source = source,
                confirmedCachedService = torrentServices[hash],
            )
        }
        else -> null
    }
}

/// In-session native-debrid resume provenance. The winning source rides with the provider/file ref so every
/// later playable is rebuilt from that exact source rather than whichever source currently ranks best.
internal data class NativeDebridResumeRef(
    val targetId: String,
    val ref: DebridCoordinator.DebridPlaybackRef,
    val source: StreamSource,
    val url: String,
    val savedAtMs: Long,
) {
    fun playable(
        resolvedUrl: String,
        resumeMs: Long,
        mediaRef: MediaRef?,
        expectedDurationMs: Long,
    ): Playable = Playable(
        url = resolvedUrl,
        title = source.title,
        viaStreamingServer = false,
        isTorrent = false,
        isDolbyVision = StreamRanking.isDolbyVision(source),
        isAtmos = StreamRanking.isAtmos(source),
        startPositionMs = resumeMs,
        mediaRef = mediaRef,
        expectedDurationMs = expectedDurationMs,
    )
}

internal fun nativeDebridResumeRef(
    targetId: String,
    winner: DebridCoordinator.PlayableWinner,
    fallbackSource: StreamSource,
    savedAtMs: Long,
): NativeDebridResumeRef {
    val source = winner.candidate.source ?: fallbackSource
    return NativeDebridResumeRef(
        targetId = targetId,
        ref = winner.ref,
        source = source,
        url = winner.ref.url,
        savedAtMs = savedAtMs,
    )
}

internal suspend fun <T> ownerBoundResult(
    expectedOwner: DebridOwnerToken?,
    currentOwner: () -> DebridOwnerToken?,
    resolve: suspend () -> Result<T>,
): Result<T> {
    if (currentOwner() != expectedOwner) {
        return Result.failure(DebridResolver.DebridException.OwnerChanged)
    }
    val result = resolve()
    return if (currentOwner() == expectedOwner) {
        result
    } else {
        Result.failure(DebridResolver.DebridException.OwnerChanged)
    }
}

/// Detail page state: the meta (hero + metadata) and the sources list load independently, mirroring
/// tvOS where the page renders the hero as soon as `meta_details.meta` is ready and the stream
/// groups stream in behind it. Both are [UiState] so a meta-add-on failure and a stream-add-on
/// failure surface separately, exactly as the engine reports them.
///
/// S05: for a series, the sources fan-out is scoped to the RESUME/PLAY target episode from the
/// start (ported from `SourcesTV/DetailView.swift`'s `seriesPrimaryEpisode` -- see [primaryEpisode]),
/// not a bare "first episode" guess, so the hero Watch/Resume button plays the right thing on first
/// load. Watched-state and library mutations dispatch through [repo] and swap [meta] with the
/// engine's freshly re-pulled snapshot, so ticks/progress/the library chip flip live with no
/// separate reload.
class DetailViewModel(
    private val repo: CatalogRepository,
    private val type: MediaType,
    private val id: String,
    appContext: Context,
) : ViewModel() {

    private val app = appContext.applicationContext

    // ---- Source-list assembly + debrid orchestration (the assembly + coordinator wave) ----
    //
    // The detail source rows are driven by [SourceListModel]: it folds ALL the lanes (the ranked engine
    // add-on groups + the user's TorBox search results + the community Singularity pool + the media-server
    // direct-play copies) into ONE ranked list through the same [StreamRanking] the app uses, off the render
    // path, coalesced (~4 rebuilds/sec) with an O(1) epoch signature. [DebridCoordinator] drives the play
    // side: cache-check fan-out (badge + rank up account-cached torrents), the multi-candidate failover race
    // (top pick dead -> next cached, honouring the label-authoritative quality gate), and the 20-min
    // fresh-link resume replay. Both were built + build-green in the prior wave; this class makes them live.
    private val debridKeys = DebridKeys(app)
    private val debrid = DebridCoordinator(DebridResolver(debridKeys), debridKeys)
    private val torbox = TorBoxSearchSource(debridKeys)
    private val singularity = SourceIndexServeSource()
    private val sourceSticky = SeriesSourceSticky(app)
    private val sourceModel = SourceListModel(viewModelScope, sourceSticky = sourceSticky)
    private val sourcePrefs = SourcePreferencesStore(app)
    private val sourcePins = SourcePinStore(app) {
        ProfileStore.sharedOrNull()?.activeProfileId ?: SourcePinStore.DEFAULT_PROFILE
    }
    private val trackPrefs = TrackPreferencesStore(app)
    private val sourceRequestFence = SourceRequestFence(sourceSticky.currentProfileId())
    private val sourceSwitchCommitGate = PlayerSourceSwitchCommitGate()
    private var sourceLoadJob: Job? = null
    private var playbackResolveJob: Job? = null
    private var profileReloadJob: Job? = null
    private val watchlistStore = WatchlistStore.shared(app)
    val watchlisted: StateFlow<Boolean> = watchlistStore.items
        .map { items -> items.any { it.id == id } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, watchlistStore.isWatchlisted(id))

    /// Gate for the [sourceModel] -> [_streams] bridge: true only after the raw engine groups for the current
    /// target have loaded, so the coalescer's empty first-paint (and the empty state at each new load) never
    /// clobbers the Loading shimmer or a load Error with an empty Success.
    @Volatile private var sourcesReady = false

    /// Account-confirmed cache evidence is one atomic, owner-tagged value. A different generation can never
    /// consume or decorate from it, even before Compose recreates this ViewModel under its owner-epoch key.
    @Volatile private var debridCacheEvidence: DebridCacheEvidence? = null

    /// In-session record of the last natively-resolved debrid source per play target (episode id, or the movie
    /// id), so a re-play of the SAME target within [DebridCoordinator.FRESH_LINK_WINDOW_MS] replays the exact
    /// stored link (or reresolves it) via [DebridCoordinator.resumePlaybackURL] instead of re-running source
    /// selection. Lost on process death (no cross-launch persistence yet), which is the safe first cut.
    private var resumeRef: NativeDebridResumeRef? = null

    private val _meta = MutableStateFlow<UiState<MetaDetail>>(UiState.Loading)
    val meta: StateFlow<UiState<MetaDetail>> = _meta.asStateFlow()

    private val _streams = MutableStateFlow<UiState<List<StreamGroup>>>(UiState.Loading)
    val streams: StateFlow<UiState<List<StreamGroup>>> = _streams.asStateFlow()

    /// The current playback request. null means "not playing"; a [Playable] means the player should be
    /// shown. The screen observes this and routes to the player; [clearPlayback] returns here on back.
    private val _playback = MutableStateFlow<Playback>(Playback.Idle)
    val playback: StateFlow<Playback> = _playback.asStateFlow()

    /// The episode whose sources are currently shown (series only). null = title-level sources (a movie,
    /// or before meta/episodes have loaded). The screen highlights the selected episode and passes
    /// its id back through [selectEpisode].
    private val _selectedEpisodeId = MutableStateFlow<String?>(null)
    val selectedEpisodeId: StateFlow<String?> = _selectedEpisodeId.asStateFlow()

    /// The season the episode list is currently browsing (series only). Seeded once from
    /// [primaryEpisode]'s season on first load (mirrors tvOS `applyPreferredSeason`'s `initialSeason ??
    /// firstUnwatchedSeason ?? …`); a manual tap on a season chip overrides it via [selectSeason] and is
    /// never clobbered afterward (no re-seed-on-data-arrival here since Android loads the full episode
    /// list in one meta response, unlike tvOS's late-streaming videos array).
    private val _selectedSeason = MutableStateFlow<Int?>(null)
    val selectedSeason: StateFlow<Int?> = _selectedSeason.asStateFlow()

    /// Set (briefly) when a watched/library mutation fails, so the screen can surface it without a
    /// second [UiState.Error] layer over the whole page. The screen is expected to read-and-clear it
    /// (call [clearMutationError]) once shown.
    private val _mutationError = MutableStateFlow<String?>(null)
    val mutationError: StateFlow<String?> = _mutationError.asStateFlow()

    /// A short, transient status line for the offline-download action (the source-row long-press "Download"):
    /// "Queued for download", the resolver's failure message, and so on. The screen renders it inline under the
    /// sources list and read-and-clears it ([clearDownloadNotice]) after a beat, so it never sticks. Kept
    /// separate from [_mutationError] (which is for watched/library writes) so a download message and a library
    /// message can never overwrite each other.
    private val _downloadNotice = MutableStateFlow<String?>(null)
    val downloadNotice: StateFlow<String?> = _downloadNotice.asStateFlow()

    /// Pin state for the sources UI (#15): the resolved effective pin (entry-first, drives the per-row
    /// "Pinned" badge via [SourcePinStore.matches]) plus whether an entry / global pin exists (drives which
    /// Unpin items the long-press menu offers). Refreshed after every pin mutation, the StateFlow analogue
    /// of Apple's `@ObservedObject pinStore` re-rendering the rows.
    data class PinUi(
        val resolved: ResolvedPin? = null,
        val hasEntry: Boolean = false,
        val hasGlobal: Boolean = false,
    )

    private val _pinUi = MutableStateFlow(PinUi())
    val pinUi: StateFlow<PinUi> = _pinUi.asStateFlow()

    /// The noun the pin menu uses for the entry scope ("show" / "movie"). Apple `SourcePinContext.entryNoun`.
    val pinEntryNoun: String get() = if (type == MediaType.SERIES) "show" else "movie"

    /// The sources-list sort ("best" / "size" / "seeders"), seeded from the remembered
    /// [SourcePreferencesStore.defaultSourceSort] and persisted on change, so the list opens the way the
    /// user last left it (Apple iOSDetailView `SourceSort` + `defaultSourceSort`, iOSDetailView.swift:4400).
    private val _sourceSort = MutableStateFlow(sourcePrefs.defaultSourceSort)
    val sourceSort: StateFlow<String> = _sourceSort.asStateFlow()

    /// Whether Smart Source Selection auto-pick is on (Settings > Sources). The screen reads it to open the
    /// sources section on an episode tap, so backing out of the auto-picked player reveals the full list
    /// (Apple's escape hatch).
    val autoPickEnabled: Boolean get() = sourcePrefs.autoPickBest

    /// The last ranking context pushed to [sourceModel], kept so a pin edit can re-push the SAME scope
    /// (episode/continuity/contentId) with only the pin + prefs refreshed, re-ranking the open list.
    private var lastCtx: SourceListModel.Context? = null

    /// Smart Source Selection auto-pick once-latch: armed when the viewer TAPS an episode while
    /// [SourcePreferencesStore.autoPickBest] is on (never on the initial programmatic selection), consumed
    /// exactly once when that episode's add-on groups land. Apple's `didAutoPick` latch inverted
    /// (iOSDetailView.swift:3433: fires once per episode-page appearance, viewer opt-in only).
    /// [playNextEpisode] arms the SAME latch (unconditionally: an accepted auto-advance must play whether
    /// or not the Smart Source setting is on), together with [pendingAdvanceHint] below.
    @Volatile private var pendingAutoPick = false

    /// The source of the last play kicked from this page, remembered so an auto-advance can carry its
    /// quality signature + bingeGroup into the NEXT episode's pick (the ranking's continuity/binge
    /// bonuses: same release family, no quality jump mid-binge). Never read outside auto-advance.
    @Volatile private var lastPlayedSource: StreamSource? = null

    /// One-shot next-episode ranking hint (continuity signature to bingeGroup of the just-finished play),
    /// consumed with [pendingAutoPick] when the advanced-to episode's add-on groups land. Null for a
    /// Smart-Source episode tap, whose auto-pick stays exactly as it was.
    @Volatile private var pendingAdvanceHint: Pair<String?, String?>? = null

    /// Next-episode PRELOAD cache (PLR-8): the pre-ranked best source for the next episode, keyed by its
    /// episode id, populated off the live fence by [warmNextEpisode] and consumed once by [playNextEpisode]
    /// so an accepted Up Next skips the source-assembly "Starting..." wait. Best-effort: a miss (never
    /// warmed, superseded, or a different episode) falls straight through to the cold resolve.
    @Volatile private var warmNextSourceByEpisode: Pair<String, StreamSource>? = null

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): the Saved chip and per-episode ticks
    /// must reflect a library/watched change made ANYWHERE -- the Library grid's trash badge, a poster
    /// long-press elsewhere, another Detail instance in the backstack -- not only this ViewModel's own
    /// [toggleLibrary]/[setWatched] calls (device finding 1b: "Detail's Saved chip stays stale until an
    /// app restart"). [repo.peekMeta] is a pure local snapshot (no re-dispatch), so this is cheap enough
    /// to run on every tick; it only replaces [_meta] once the initial load (below) has already
    /// succeeded, so it can never race ahead of or clobber the first load.
    init {
        viewModelScope.launch {
            repo.ctxUpdates().collect {
                if (_meta.value !is UiState.Success) return@collect
                repo.peekMeta(type, id)?.let { fresh -> _meta.value = UiState.Success(fresh) }
            }
        }
        // Start the assembly pipeline and bridge its ranked output to [_streams]. The bridge is gated by
        // [sourcesReady] so the coalescer's empty first paint (bind paints once immediately, and every new
        // load resets rawGroups to empty) never overwrites the Loading shimmer or a load Error.
        sourceModel.bind(torbox, singularity)
        viewModelScope.launch {
            sourceModel.state.collect { st ->
                val token = sourceRequestFence.currentToken()
                if (
                    sourcesReady &&
                    token != null &&
                    st.requestGeneration == token.generation &&
                    st.streamId == token.targetId &&
                    sourceRequestFence.accepts(token, sourceSticky.currentProfileId())
                ) {
                    _streams.value = UiState.Success(st.groups)
                }
            }
        }
        ProfileStore.sharedOrNull()?.let { profileStore ->
            viewModelScope.launch {
                var observedProfile = sourceSticky.currentProfileId()
                profileStore.activeProfile
                    .map { profileStore.activeProfileId }
                    .distinctUntilChanged()
                    .collect { profileId ->
                        if (profileId != observedProfile) {
                            observedProfile = profileId
                            rebuildForProfile(profileId)
                        }
                    }
            }
        }
        val initialProfile = sourceSticky.currentProfileId()
        profileReloadJob = viewModelScope.launch {
            if (type == MediaType.SERIES) {
                // A series' hero Watch/Resume target depends on which episode + watched state the meta
                // carries, so meta must land before the sources fan-out is scoped.
                val loaded = repo.meta(type, id)
                if (sourceSticky.currentProfileId() != initialProfile) return@launch
                _meta.value = loaded.toUiState()
                val detail = (_meta.value as? UiState.Success)?.data
                val primary = detail?.let { primaryEpisodeOf(it) }
                if (primary != null) {
                    _selectedSeason.value = primary.first.season
                    // Programmatic first selection: never arms the auto-pick latch (auto-playing on merely
                    // OPENING a detail page would be aggressive; Apple fires only on the episode source
                    // page the viewer navigated to).
                    selectEpisode(primary.first.id, userTap = false)
                } else {
                    startSourceLoad(null)
                }
            } else {
                // Movie: land meta first (the hero + the media-server scoping both read it), then load the
                // title-level sources through the assembly.
                val loaded = repo.meta(type, id)
                if (sourceSticky.currentProfileId() != initialProfile) return@launch
                _meta.value = loaded.toUiState()
                startSourceLoad(null)
            }
        }
    }

    /// Reload sources scoped to a series [episodeId] (the engine `CoreVideo.id`). A no-op if the same episode
    /// is re-selected. Movies never call this. [loadSources] drives the Loading -> result transition.
    /// [userTap] arms the Smart Source Selection auto-pick (viewer opt-in via Settings > Sources): a REAL
    /// episode tap with the toggle on plays the best-ranked source straight away once its add-on groups
    /// land, instead of making the viewer pick from the list. The init-time programmatic selection passes
    /// false, so opening a detail page never auto-plays.
    fun selectEpisode(episodeId: String, userTap: Boolean = true) {
        if (_selectedEpisodeId.value == episodeId) return
        _selectedEpisodeId.value = episodeId
        pendingAutoPick = userTap && sourcePrefs.autoPickBest
        startSourceLoad(episodeId)
    }

    private fun startSourceLoad(episodeId: String?) {
        sourceLoadJob?.cancel()
        val token = sourceRequestFence.begin(sourceSticky.currentProfileId(), episodeId)
        sourceLoadJob = viewModelScope.launch { loadSources(episodeId, token) }
    }

    private fun rebuildForProfile(profileId: String) {
        sourceLoadJob?.cancel()
        playbackResolveJob?.cancel()
        profileReloadJob?.cancel()
        val invalidGeneration = sourceRequestFence.invalidate(profileId)
        sourceSticky.onProfileChanged()
        torbox.reset(invalidGeneration, clearCache = true)
        singularity.reset(invalidGeneration)
        sourceModel.setRawGroups(emptyList())
        sourceModel.setMediaServerGroups(emptyList())
        sourceModel.setContext(SourceListModel.Context(requestGeneration = invalidGeneration))
        sourcesReady = false
        debridCacheEvidence = null
        resumeRef = null
        lastCtx = null
        lastPlayedSource = null
        pendingAutoPick = false
        pendingAdvanceHint = null
        warmNextSourceByEpisode = null
        failedHandlesByTarget.clear()
        _streams.value = UiState.Loading
        _playback.value = Playback.Idle
        _meta.value = UiState.Loading
        profileReloadJob = viewModelScope.launch {
            val loaded = repo.meta(type, id)
            if (sourceSticky.currentProfileId() != profileId) return@launch
            _meta.value = loaded.toUiState()
            val detail = loaded.getOrNull()
            val oldTarget = _selectedEpisodeId.value
            val target = if (type == MediaType.SERIES) {
                detail?.videos?.firstOrNull { it.id == oldTarget }
                    ?: detail?.let { primaryEpisodeOf(it)?.first }
            } else {
                null
            }
            _selectedEpisodeId.value = target?.id
            target?.let { _selectedSeason.value = it.season }
            startSourceLoad(target?.id)
        }
    }

    /// Load + assemble the sources for [episodeId] (null = movie / title-level) through [sourceModel]: feed
    /// the raw engine add-on groups plus the TorBox / Singularity / media-server lanes and drive the detail
    /// rows from the assembled, ranked, coalesced [SourceListState]. The add-on groups paint immediately; the
    /// contributor lanes + the account cache badge fold in a beat later through the coalescer, the "sources
    /// stream in behind the hero" shape. Fail-soft: an add-on-load failure surfaces as [UiState.Error] and
    /// leaves any still-arriving contributor lane to be handled on the next load.
    private suspend fun loadSources(episodeId: String?, request: SourceRequestFence.Token) {
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return
        // Reset per-target state so a superseded episode's rows / cache badges can never leak into the new one.
        sourcesReady = false
        debridCacheEvidence = null
        _streams.value = UiState.Loading
        sourceModel.setRawGroups(emptyList())

        val detail = (_meta.value as? UiState.Success)?.data
        val imdb = id.takeIf { it.startsWith("tt") }
        val ep = episodeId?.let { eid -> detail?.videos?.firstOrNull { it.id == eid } }
        val season = if (type == MediaType.SERIES) ep?.season else null
        val episodeNum = if (type == MediaType.SERIES) ep?.episode else null
        val contentId = when {
            type == MediaType.SERIES && ep == null -> null
            else -> CanonicalContentIdentity.imdb(imdb, season, episodeNum)
        }

        // Kick the contributor lanes + install the ranking context BEFORE the raw feed, so the first coalesced
        // rebuild ranks against the real user prefs/pin (never the empty default, which would clobber the
        // globally-installed reading) and merges every lane in one pass.
        val advanceHint = pendingAdvanceHint
        if (contentId != null) {
            torbox.refresh(imdb, season, episodeNum, request.generation)
        } else {
            torbox.reset(request.generation)
        }
        singularity.refresh(
            contentId,
            isSignedIn(),
            request.generation,
        )
        val ctx = buildContext(episodeId, contentId, request, advanceHint)
        lastCtx = ctx
        sourceModel.setContext(ctx)
        _pinUi.value = readPinUi()
        // Dormant + no network when no media server is connected (matches the pre-assembly guard).
        val serverGroups = if (MediaServerRepository.hasServers) mediaServerGroups(episodeId) else emptyList()
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return
        sourceModel.setMediaServerGroups(serverGroups)

        repo.streams(
            type = type,
            id = id,
            episodeId = episodeId,
            rememberedQuality = advanceHint?.first,
            wantedAddon = advanceHint?.let { sourceSticky.preference(id)?.addon },
        ).fold(
            onSuccess = { raw ->
                // Immediate paint of the ranked add-on groups (already ranked by the engine repo), then feed
                // the model so the fuller assembled + re-ranked list refines it a beat later.
                if (
                    episodeId == _selectedEpisodeId.value &&
                    sourceRequestFence.accepts(request, sourceSticky.currentProfileId())
                ) {
                    // The assembly coalescer applies this same pure filter later, but immediate paint and the
                    // once-latched Smart Source pick run before that publication. Filter their shared input
                    // now so direct-links-only can never flash or auto-play a raw torrent. Keep [raw] for the
                    // model/capture/cache lanes: their display assembly filters before ranking, while capture
                    // intentionally sees eligible torrent descriptors before the viewer-only display filter.
                    val displayRaw = SourceListModel.directLinkDisplayGroups(raw, ctx.directLinksOnly)
                    sourcesReady = true
                    _streams.value = UiState.Success(displayRaw)
                    sourceModel.setRawGroups(raw)
                    runCacheCheck(raw, episodeId, season, episodeNum, request, ctx.contentId)
                    // Smart Source Selection auto-pick (viewer opt-in, once per episode tap): play the
                    // best-ranked source of the FRESH raw groups straight away. Ranked directly (not via
                    // [bestSource]) because the assembly coalescer may still hold the previous episode's
                    // list at this instant; auto-playing a stale episode's source would be worse than no
                    // auto-pick. Backing out of the player reveals the full source list (the escape hatch).
                    //
                    // An auto-ADVANCE pick additionally carries the just-finished play's continuity
                    // signature + bingeGroup so the ranking's next-episode bonuses keep the binge on the
                    // same release family; it also reports a no-source dead end through [_playback] so
                    // the shell's Up Next overlay can bail instead of sitting on "Starting…" forever.
                    if (pendingAutoPick) {
                        pendingAutoPick = false
                        val hint = pendingAdvanceHint
                        pendingAdvanceHint = null
                        val sticky = sourceSticky.preference(id)
                        val unhealthy: (String) -> Boolean = { addon -> ProviderHealth.penaltyActive(addon) }
                        val pick = if (hint != null) {
                            val assembled = sourceModel.awaitSettledTarget(
                                requestGeneration = request.generation,
                                streamId = episodeId,
                                deadlineMs = AUTO_NEXT_ASSEMBLY_DEADLINE_MS,
                            )
                            if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return@fold
                            assembled?.best
                        } else {
                            StreamRanking.best(
                                displayRaw,
                                continuity = null,
                                pin = currentPin(),
                                sticky = sticky,
                                providerPenalty = unhealthy,
                                prefs = ctx.prefs,
                            )
                        }
                        when {
                            pick != null -> playAutomatically(pick)
                            hint != null -> _playback.value = Playback.Failed("No playable source for the next episode.")
                        }
                    }
                }
            },
            onFailure = {
                if (
                    episodeId == _selectedEpisodeId.value &&
                    sourceRequestFence.accepts(request, sourceSticky.currentProfileId())
                ) {
                    // An auto-advance load failure must reach the shell's Up Next overlay (it observes
                    // [playback], not [streams]); a Smart-Source tap keeps today's streams-Error surface.
                    if (pendingAutoPick && pendingAdvanceHint != null) {
                        _playback.value = Playback.Failed(it.message ?: "Couldn't load the next episode's sources.")
                    }
                    pendingAutoPick = false
                    pendingAdvanceHint = null
                    _streams.value = UiState.Error(it.message ?: "Something went wrong loading your add-ons.")
                }
            },
        )
    }

    /// The frozen ranking context [sourceModel] assembles against: the real user preference snapshot + the
    /// effective per-title / provider pin (so a re-rank of the merged list keeps a pinned source on top and
    /// honours the user's filters), the chosen episode's [SourceListModel.Context.streamId], and the
    /// canonical [SourceListModel.Context.contentId] that owns TorBox rows and seeds the Singularity hoard.
    private fun buildContext(
        episodeId: String?,
        contentId: String?,
        request: SourceRequestFence.Token,
        advanceHint: Pair<String?, String?>?,
    ): SourceListModel.Context =
        SourceListModel.Context(
            metaId = id,
            streamId = episodeId,
            requestGeneration = request.generation,
            continuity = advanceHint?.first,
            binge = advanceHint?.second,
            // isKids rides the snapshot so a Kids profile's content guard (hard-hide adult/junk; Avoid
            // words always DROP, never merely demote) is live in the frozen reading, mirroring Apple's
            // `ProfileStore.activeIsKids()` read inside `passesUserFilters`.
            prefs = sourcePrefs.snapshot(
                trackPrefs.current.audioLanguages,
                isKids = ProfileStore.sharedOrNull()?.activeIsKids == true,
            ),
            directLinksOnly = PlaybackBehaviorSettings.directLinksOnly(app),
            pin = currentPin(),
            contentId = contentId,
        )

    /// Query the user's debrid account for which of the loaded torrents it has CACHED, then use the result to
    /// (a) feed the failover race + resume ([cachedHashes] / [cachedUsenetURLs]) and (b) badge + rank up the
    /// account-cached add-on torrents that carried no cache tag (re-fed to [sourceModel] so the same
    /// [StreamRanking] the app uses lights the badge + applies the cache bonus). No key -> no network, no
    /// badge. Guards against a superseding episode selection landing first.
    private fun runCacheCheck(
        raw: List<StreamGroup>,
        episodeId: String?,
        season: Int?,
        episodeNum: Int?,
        request: SourceRequestFence.Token,
        contentId: String?,
    ) {
        if (!debrid.hasAnyResolver && !debrid.hasUsenetResolver) return
        val owner = debridKeys.ownerToken() ?: return
        val credentialRevision = debridKeys.currentCredentialRevision()
        viewModelScope.launch {
            // Gather over the CURRENT lanes for this title (raw add-on groups + whatever the TorBox / Singularity
            // contributors have already published), never a possibly-stale prior assembly. Late-arriving TorBox
            // torrents self-badge from the index's own check_cache tag, so they need no account round trip here.
            val laneStreams = raw.flatMap { it.streams } + torbox.streamsFor(contentId) + singularity.streams.value
            val hashes = laneStreams
                .mapNotNull { it.infoHash?.trim()?.lowercase()?.takeIf { h -> h.isNotEmpty() } }
                .distinct()
            if (hashes.isEmpty()) return@launch
            val hits = debrid.cacheCheck(hashes, owner)
            if (
                episodeId != _selectedEpisodeId.value ||
                !sourceRequestFence.accepts(request, sourceSticky.currentProfileId()) ||
                !debridKeys.isCurrent(owner) ||
                debridKeys.currentCredentialRevision() != credentialRevision
            ) {
                return@launch
            }
            // Usenet cached is already index-confirmed in the stream text (the TorBox search check_cache tag),
            // so derive the failover's cached-usenet set from that rather than a second md5 round trip.
            val cachedUsenetUrls = laneStreams
                .filter { it.isUsenet && StreamRanking.isCachedSource(it) }
                .mapNotNull { it.nzbUrl }
                .toSet()
            val torrentServices = torrentServicesFromCacheHits(hits)
            debridCacheEvidence = DebridCacheEvidence(
                owner = owner,
                credentialRevision = credentialRevision,
                torrentServices = torrentServices,
                usenetUrls = cachedUsenetUrls,
            )
            // Badge + rank up any account-cached add-on torrent the add-on itself did not tag.
            val decorated = decorateCached(raw, torrentServices.keys)
            if (
                decorated !== raw &&
                episodeId == _selectedEpisodeId.value &&
                sourceRequestFence.accepts(request, sourceSticky.currentProfileId()) &&
                debridKeys.isCurrent(owner) &&
                debridKeys.currentCredentialRevision() == credentialRevision
            ) {
                sourceModel.setRawGroups(decorated)
            }
        }
    }

    /// Fold a "cached" marker into the add-on torrents whose infoHash the account confirmed cached and that do
    /// not already read cached, so the text-based [StreamRanking] lights the badge + applies the +cache bonus.
    /// The marker rides the description AND a cache-busting id suffix (the score/quality caches key on the id),
    /// while the id's handle (`substringBefore('#')`, read by the resolve + dedup paths) is left untouched.
    /// Returns [groups] unchanged (same instance) when nothing needed marking.
    private fun decorateCached(groups: List<StreamGroup>, hashes: Set<String>): List<StreamGroup> {
        if (hashes.isEmpty()) return groups
        var changed = false
        val out = groups.map { group ->
            val streams = group.streams.map { s ->
                val h = s.infoHash?.trim()?.lowercase()
                if (h != null && h in hashes && !StreamRanking.isCachedSource(s)) {
                    changed = true
                    val desc = s.description?.let { "$it · $CACHED_MARKER" } ?: CACHED_MARKER
                    s.copy(description = desc, id = s.id + CACHED_ID_SUFFIX)
                } else {
                    s
                }
            }
            group.copy(streams = streams)
        }
        return if (changed) out else groups
    }

    /// The effective per-title (else provider) source pin, so a re-rank of the merged list floats a pinned
    /// source to the top exactly as the engine repo's first rank does.
    private fun currentPin(): ResolvedPin? = sourcePins.effectivePin(SourcePinContext(id, type == MediaType.SERIES))

    private fun pinContext(): SourcePinContext = SourcePinContext(id, type == MediaType.SERIES)

    private fun readPinUi(): PinUi {
        val ctx = pinContext()
        return PinUi(
            resolved = sourcePins.effectivePin(ctx),
            hasEntry = sourcePins.entryPin(ctx) != null,
            hasGlobal = sourcePins.global != null,
        )
    }

    /// Pin [source] for this title ([SourcePinScope.ENTRY]) or every title ([SourcePinScope.GLOBAL]), from
    /// the source row's long-press menu. A pin is a strong preference (it tops the list + the auto-pick),
    /// never a hard lock; the player failover still hops off it if dead. Mirrors Apple's `pinMenu` actions.
    fun pinSource(source: StreamSource, scope: SourcePinScope) {
        sourcePins.pin(source, source.addon, scope, pinContext())
        onPinsChanged()
    }

    /// Remove the entry / global pin. Mirrors Apple's Unpin menu actions.
    fun unpinSource(scope: SourcePinScope) {
        sourcePins.unpin(scope, pinContext())
        onPinsChanged()
    }

    /// A pin edit changes rank order (pinBonus) and the row badges: refresh the pin UI and re-push the last
    /// ranking context with the new effective pin so [SourceListModel] re-ranks the OPEN list (the store
    /// already invalidated the memoized scores). The StateFlow analogue of Apple's `@ObservedObject
    /// pinStore` + published-groups re-rank.
    private fun onPinsChanged() {
        _pinUi.value = readPinUi()
        lastCtx?.let { ctx ->
            val updated = ctx.copy(pin = currentPin())
            lastCtx = updated
            sourceModel.setContext(updated)
        }
    }

    /// Remember the sources-list sort ("best" / "size" / "seeders") and persist it through
    /// [SourcePreferencesStore.defaultSourceSort], so the list opens the way the user last left it
    /// (Apple iOSDetailView.swift:4401's `onChange(of: sortMode)` write-through).
    fun setSourceSort(key: String) {
        if (_sourceSort.value == key) return
        _sourceSort.value = key
        sourcePrefs.defaultSourceSort = key
    }

    /// Whether the account is signed in, gating the community Singularity SERVE lane. Reads the engine's live
    /// auth state (the engine repo is also the [AuthRepository]); false for the offline preview repo.
    private fun isSignedIn(): Boolean = (repo as? AuthRepository)?.authState?.value is AuthState.SignedIn

    /// Build the media-server direct-play groups for the current title, scoped to the chosen [episodeId]'s
    /// season/number for a series. Returns `[]` before meta loads or with no server connected.
    private suspend fun mediaServerGroups(episodeId: String?): List<StreamGroup> {
        val detail = (_meta.value as? UiState.Success)?.data ?: return emptyList()
        val ep = episodeId?.let { eid -> detail.videos.firstOrNull { it.id == eid } }
        val season = if (type == MediaType.SERIES) ep?.season?.takeIf { it > 0 } else null
        val episode = if (type == MediaType.SERIES) ep?.episode?.takeIf { it > 0 } else null
        val year = detail.releaseInfo?.take(4)?.toIntOrNull()
        return MediaServerRepository.directPlayGroups(
            detailId = id,
            season = season,
            episode = episode,
            title = detail.name,
            year = year,
        )
    }

    /// Browse a different season's episode list (does NOT touch the sources selection -- the hero keeps
    /// showing whichever episode's sources were last chosen via [selectEpisode]).
    fun selectSeason(season: Int) {
        _selectedSeason.value = season
    }

    /// Resolve a chosen source to a [Playable] and request playback. Drives a Resolving -> Ready /
    /// Failed transition so the row can show progress and a resolve failure surfaces instead of
    /// silently doing nothing.
    fun play(source: StreamSource) = play(source, manualPick = true, startPositionOverrideMs = null)

    private fun playAutomatically(source: StreamSource, startPositionOverrideMs: Long? = null) =
        play(source, manualPick = false, startPositionOverrideMs = startPositionOverrideMs)

    private fun play(
        source: StreamSource,
        manualPick: Boolean,
        startPositionOverrideMs: Long?,
    ) {
        if (_playback.value is Playback.Resolving) return
        val request = sourceRequestFence.currentToken() ?: return
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return
        val stickyWrite = if (manualPick && type == MediaType.SERIES) sourceSticky.capture(id) else null
        lastPlayedSource = source
        _playback.value = Playback.Resolving
        val resumeMs = startPositionOverrideMs?.coerceAtLeast(0L) ?: resumeOffsetMs()
        val episode = currentModelEpisode()
        val actionOwner = debridKeys.ownerToken()
        // Resolve the external-sync identity ONCE here, the one place that knows the meta id + the chosen
        // episode, and ride it on the Playable so the player can scrobble it to Trakt / SIMKL (the engine
        // resolve() only knows the opaque source, not the title identity). Null for an id we can't map, in
        // which case playback simply doesn't scrobble.
        val ref = currentMediaRef()
        playbackResolveJob?.cancel()
        playbackResolveJob = viewModelScope.launch {
            val result = resolveForOwner(source, episode, actionOwner)
            if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return@launch
            _playback.value = result.fold(
                onSuccess = { playable ->
                    if (playable.url.isBlank()) {
                        Playback.Failed("Could not start this source.")
                    } else {
                        Playback.Ready(
                            playable.copy(
                            startPositionMs = if (resumeMs > 0L) resumeMs else playable.startPositionMs,
                            mediaRef = ref,
                            expectedDurationMs = expectedRuntimeMs(),
                            posterUrl = nowPlayingPoster(episode),
                            isLive = isLivePlayback(),
                            episodeTitle = episode?.title?.takeIf { it.isNotBlank() },
                            ),
                        )
                    }
                },
                onFailure = { Playback.Failed(it.message ?: "Could not start this source.") },
            )
            // Persistence follows successful publication. A failed resolve, blank URL, superseded target, or
            // profile switch leaves the previous preference untouched.
            if (_playback.value is Playback.Ready && stickyWrite != null) {
                sourceSticky.record(stickyWrite, source.addon, source.bingeGroup)
            }
        }
    }

    /**
     * Resolve an in-player source or quality pick without publishing through [playback]. The outgoing player
     * remains alive while this suspends. Resolution itself has no source-identity or sticky side effects: those
     * are captured behind [PlayerSourceSwitchResolution]'s explicit commit seam and run only after the player host
     * accepts the exact outer-session/request token. A failed or stale resolve therefore cannot dismiss or poison
     * the healthy playback session underneath it.
     */
    suspend fun resolveSourceSwitch(source: StreamSource): Result<PlayerSourceSwitchResolution> {
        if (_playback.value is Playback.Resolving) return Result.failure(IllegalStateException())
        val request = sourceRequestFence.currentToken() ?: return Result.failure(IllegalStateException())
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
            return Result.failure(IllegalStateException())
        }
        val stickyWrite = if (type == MediaType.SERIES) sourceSticky.capture(id) else null
        val episode = currentModelEpisode()
        val actionOwner = debridKeys.ownerToken()
        val ref = currentMediaRef()
        val result = resolveForOwner(source, episode, actionOwner)
        if (
            !isActionOwnerCurrent(actionOwner) ||
            !sourceRequestFence.accepts(request, sourceSticky.currentProfileId())
        ) {
            return Result.failure(IllegalStateException(OWNER_CHANGED_MESSAGE))
        }
        return result.mapCatching { resolved ->
            if (resolved.url.isBlank()) throw IllegalStateException()
            PlayerSourceSwitchResolution(
                playable = resolved.copy(
                    mediaRef = ref,
                    expectedDurationMs = expectedRuntimeMs(),
                    posterUrl = nowPlayingPoster(episode),
                    isLive = isLivePlayback(),
                    episodeTitle = episode?.title?.takeIf { it.isNotBlank() },
                ),
                commitGate = sourceSwitchCommitGate,
                commitAuthorityIsCurrent = {
                    isActionOwnerCurrent(actionOwner) &&
                        sourceRequestFence.accepts(request, sourceSticky.currentProfileId())
                },
                commitAccepted = {
                    lastPlayedSource = source
                    stickyWrite?.let { sourceSticky.record(it, source.addon, source.bingeGroup) }
                },
            )
        }
    }

    /**
     * Resolve the viewer's in-player episode pick through the same target-scoped source assembly and
     * owner fences as Detail playback. The mounted player stays alive while the target episode loads;
     * [PlayerSourceSwitchResolution]'s commit seam publishes identity only after the player accepts its
     * exact request authority. Mirrors [resolveSourceSwitch], scoped to a new episode target.
     */
    suspend fun resolveEpisodeSwitch(episodeId: String): Result<PlayerSourceSwitchResolution> {
        if (type != MediaType.SERIES || _playback.value is Playback.Resolving) {
            return Result.failure(IllegalStateException())
        }
        val detail = (_meta.value as? UiState.Success)?.data
            ?: return Result.failure(IllegalStateException())
        val target = detail.videos.firstOrNull { it.id == episodeId }
            ?: return Result.failure(IllegalStateException())
        val previousEpisodeId = _selectedEpisodeId.value
        val previousSeason = _selectedSeason.value
        _selectedEpisodeId.value = target.id
        _selectedSeason.value = target.season
        pendingAutoPick = false
        pendingAdvanceHint = null
        startSourceLoad(target.id)
        val request = sourceRequestFence.currentToken()
            ?: return Result.failure(IllegalStateException())
        val selectionLease = EpisodeSwitchSelectionLease(
            request = request,
            targetEpisodeId = target.id,
            previousEpisodeId = previousEpisodeId,
            previousSeason = previousSeason,
        )
        fun restorePreviousTargetIfCurrent() {
            selectionLease.rollbackIfOwned(
                currentRequest = sourceRequestFence.currentToken(),
                selectedEpisodeId = _selectedEpisodeId.value,
            ) { restoreEpisodeId, restoreSeason ->
                _selectedEpisodeId.value = restoreEpisodeId
                _selectedSeason.value = restoreSeason
                startSourceLoad(restoreEpisodeId)
            }
        }
        return withEpisodeSwitchCancellationRollback(::restorePreviousTargetIfCurrent) {
            val groups = withTimeoutOrNull(EPISODE_SWITCH_SOURCE_DEADLINE_MS) {
                _streams.first { state ->
                    sourceRequestFence.currentToken() == request &&
                        state is UiState.Success && state.data.any { it.streams.isNotEmpty() }
                } as UiState.Success
            }?.data ?: run {
                restorePreviousTargetIfCurrent()
                return@withEpisodeSwitchCancellationRollback Result.failure(
                    IllegalStateException("No playable source for this episode."),
                )
            }
            val settled = sourceModel.awaitSettledTarget(
                requestGeneration = request.generation,
                streamId = target.id,
                deadlineMs = EPISODE_SWITCH_ASSEMBLY_DEADLINE_MS,
            )
            if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
                return@withEpisodeSwitchCancellationRollback Result.failure(IllegalStateException())
            }
            val source = settled?.best ?: StreamRanking.best(
                groups = groups,
                continuity = lastPlayedSource?.let(StreamRanking::signature),
                binge = lastPlayedSource?.bingeGroup,
                pin = currentPin(),
                sticky = sourceSticky.preference(id),
                providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
                prefs = lastCtx?.prefs ?: StreamRanking.reading(),
            ) ?: run {
                restorePreviousTargetIfCurrent()
                return@withEpisodeSwitchCancellationRollback Result.failure(
                    IllegalStateException("No playable source for this episode."),
                )
            }
            val actionOwner = debridKeys.ownerToken()
            val result = resolveForOwner(source, target, actionOwner)
            if (
                !isActionOwnerCurrent(actionOwner) ||
                !sourceRequestFence.accepts(request, sourceSticky.currentProfileId())
            ) {
                return@withEpisodeSwitchCancellationRollback Result.failure(
                    IllegalStateException(OWNER_CHANGED_MESSAGE),
                )
            }
            val year = detail.releaseInfo?.take(4)?.toIntOrNull()
            val mediaRef = buildMediaRef(type = type, metaId = id, episode = target, title = detail.name, year = year)
            val resolution = result.mapCatching { resolved ->
                if (resolved.url.isBlank()) throw IllegalStateException()
                PlayerSourceSwitchResolution(
                    playable = resolved.copy(
                        startPositionMs = 0L,
                        mediaRef = mediaRef,
                        expectedDurationMs = expectedRuntimeMs(),
                        posterUrl = nowPlayingPoster(target),
                        isLive = isLivePlayback(),
                        episodeTitle = target?.title?.takeIf { it.isNotBlank() },
                    ),
                    resolvedSource = source,
                    commitGate = sourceSwitchCommitGate,
                    commitAuthorityIsCurrent = {
                        isActionOwnerCurrent(actionOwner) &&
                            sourceRequestFence.accepts(request, sourceSticky.currentProfileId()) &&
                            _selectedEpisodeId.value == target.id
                    },
                    commitAccepted = {
                        lastPlayedSource = source
                        resumeRef = null
                    },
                )
            }
            if (resolution.isFailure) restorePreviousTargetIfCurrent()
            resolution
        }
    }

    /// Save a chosen source for OFFLINE viewing. This is the download subsystem's create entry point (the one
    /// [DownloadManager.CREATE_PATH_WIRED] gates on): it resolves the source to a concrete URL through the SAME
    /// [repo.resolve] the play path uses -- so a debrid torrent is unlocked to its direct link and a direct /
    /// HTTP source passes straight through -- then hands that URL to [DownloadManager.download], which enqueues
    /// the [com.vortx.android.downloads.DownloadWorker]. A finished download plays from the local file with no
    /// network (see [com.vortx.android.ui.screens.DownloadsScreen]).
    ///
    /// The record's ids ([contentId] / [videoId] / [type] / [season] / [episode]) are the SAME ones the play
    /// path threads, so a downloaded title lands in the right per-show folder and (once PlaybackMeta is ported)
    /// records progress against the same library item as a streamed play. For a series the download targets the
    /// currently-selected episode -- the sources list is already scoped to it -- so the episode's own id/season/
    /// number ride the record; for a movie the meta id is both the content and video id.
    ///
    /// Fail-soft, honestly: a raw torrent with no debrid key cannot be resolved to a direct URL on Android
    /// (torrent-to-disk needs the streaming server, not yet wired), so [repo.resolve] throws and its message is
    /// shown on [_downloadNotice] rather than silently doing nothing. An HLS / non-media source is caught inside
    /// [DownloadManager.download] (it returns a FAILED record whose error text the notice surfaces).
    fun download(source: StreamSource) {
        val detail = (_meta.value as? UiState.Success)?.data ?: return
        val episode = detail.videos.firstOrNull { it.id == _selectedEpisodeId.value }
        val actionOwner = debridKeys.ownerToken()
        _downloadNotice.value = "Preparing download…"
        viewModelScope.launch {
            resolveForOwner(source, episode, actionOwner).fold(
                onSuccess = { playable ->
                    if (!isActionOwnerCurrent(actionOwner)) {
                        _downloadNotice.value = OWNER_CHANGED_MESSAGE
                        return@fold
                    }
                    val debridDownloadOwner = actionOwner?.takeIf {
                        (source.isTorrent || source.isUsenet) && !playable.viaStreamingServer
                    }
                    val record = DownloadManager.download(
                        stream = source,
                        // contentId is the library id: the series id for an episode, the movie id for a movie
                        // (which equals videoId). videoId is the engine CoreVideo id (imdbId:season:episode) for
                        // an episode, or the movie id. Same identities the play path uses.
                        contentId = id,
                        videoId = episode?.id ?: id,
                        type = if (type == MediaType.SERIES) "series" else "movie",
                        name = detail.name,
                        poster = detail.poster,
                        season = episode?.season?.takeIf { it >= 0 },
                        episode = episode?.episode?.takeIf { it > 0 },
                        resolvedUrl = playable.url,
                        sourceName = source.addon,
                        qualityText = StreamRanking.qualityLabel(source),
                        isDolbyVision = playable.isDolbyVision,
                        isAtmos = playable.isAtmos,
                        // Forward the resolved request headers (the stream's behaviorHints.proxyHeaders.request,
                        // decoded by the engine mapping) so a header-gated CDN serves the download too.
                        requestHeaders = playable.headers.takeIf { it.isNotEmpty() },
                        debridOwnerIdentity = debridDownloadOwner?.identity,
                        debridOwnerGeneration = debridDownloadOwner?.generation,
                    )
                    _downloadNotice.value = downloadNoticeFor(record)
                },
                onFailure = { _downloadNotice.value = it.message ?: "Couldn't start this download." },
            )
        }
    }

    /// The transient status line for a just-created download, read off the record [DownloadManager.download]
    /// returned: a FAILED record (HLS / non-media, caught inside the manager) shows its own honest reason; a
    /// completed / in-flight duplicate says so; a fresh one reports queued vs downloading.
    private fun downloadNoticeFor(record: DownloadRecord): String = when (record.state) {
        DownloadState.FAILED -> record.errorText ?: "This source can't be downloaded."
        DownloadState.COMPLETED -> "Already downloaded — find it in Settings › Downloads."
        DownloadState.QUEUED -> "Queued — starting when a download slot frees up."
        DownloadState.PAUSED -> "Resuming this download."
        DownloadState.DOWNLOADING -> "Downloading — track it in Settings › Downloads."
    }

    /// Read-and-clear the download notice (the screen calls this after showing it for a beat).
    fun clearDownloadNotice() {
        _downloadNotice.value = null
    }

    /// Play the meta's YouTube trailer (the detail/hero Trailer affordance). Resolves the trailer id through
    /// [TrailerCoordinator] -- the on-device client resolver (free 1080p from the user's IP, flag-gated) FIRST,
    /// with the worker fallback on a miss, the whole resolve internally bounded so a slow InnerTube ladder never
    /// hangs the tap -- then posts the resulting [Playable] through the SAME [_playback] -> onPlay pipeline every
    /// source uses. The trailer [Playable] carries no [MediaRef] (a trailer never scrobbles) and `isTrailer =
    /// true` (the shell skips library/progress side effects). No-op when the meta carries no trailer id or a
    /// resolve/play is already running.
    fun playTrailer() {
        if (_playback.value is Playback.Resolving) return
        val request = sourceRequestFence.currentToken() ?: return
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return
        val detail = (_meta.value as? UiState.Success)?.data ?: return
        val ytId = detail.trailerYouTubeId ?: return
        _playback.value = Playback.Resolving
        playbackResolveJob?.cancel()
        playbackResolveJob = viewModelScope.launch {
            val playable = TrailerCoordinator.trailerPlayable(
                context = app,
                youTubeId = ytId,
                title = detail.name,
                imdbId = id.takeIf { it.startsWith("tt") },
                year = detail.releaseInfo?.take(4),
                mediaType = if (type == MediaType.SERIES) "series" else "movie",
            )
            if (sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
                _playback.value = playable?.let { Playback.Ready(it) }
                    ?: Playback.Failed("This trailer isn't available right now.")
            }
        }
    }

    /// The hero Watch/Resume action: play the LABELED BEST source, but robustly. Three tiers, in order:
    ///
    ///  1. CW RESUME: if this exact target was resolved to a native debrid link earlier this session, replay
    ///     it through [DebridCoordinator.resumePlaybackURL] -- the stored link straight back when it is still
    ///     inside the 20-min fresh window, or a freshly reresolved link for the SAME file/provider otherwise,
    ///     with NO re-run of source selection (owner requirement: resume plays THAT source).
    ///  2. FAILOVER: race the account-confirmed-cached candidates in rank order ([resolveFirstPlayable]),
    ///     honouring the label-authoritative quality gate, so a dead / false-cached top pick never blocks a
    ///     genuinely-cached one and the played quality never drops below the "Watch Now" promise. The winning
    ///     fresh link is remembered for a later in-session resume.
    ///  3. FALLBACK: single-resolve the labeled best through the engine repo (a direct / media-server / single
    ///     debrid source, or the promised confirmed-cached best when the gate refused every lower-res winner).
    /// [fromStart] (DET-14) plays the SAME best-ranked source from 0:00, ignoring the saved resume
    /// point WITHOUT clearing it (the library `timeOffset` is left untouched, so the primary Resume
    /// still seeks there next time). It only forces the player's start position to zero across all
    /// three legs below by not reading [resumeOffsetMs]; nothing engine/account state is written.
    fun playBest(fromStart: Boolean = false) {
        if (_playback.value is Playback.Resolving) return
        val request = sourceRequestFence.currentToken() ?: return
        if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return
        val groups = (_streams.value as? UiState.Success)?.data ?: return
        val best = bestSource() ?: return
        lastPlayedSource = best
        _playback.value = Playback.Resolving
        val resumeMs = if (fromStart) 0L else resumeOffsetMs()
        val ref = currentMediaRef()
        val targetId = _selectedEpisodeId.value ?: id
        val episode = currentModelEpisode()
        val debridEpisode = episode?.debridEpisodeForResolve()
        val actionOwner = debridKeys.ownerToken()
        playbackResolveJob?.cancel()
        playbackResolveJob = viewModelScope.launch {
            if (!isActionOwnerCurrent(actionOwner) || !sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
                _playback.value = Playback.Failed(OWNER_CHANGED_MESSAGE)
                return@launch
            }
            // 1) CW resume: replay the exact stored debrid source for this target if we have one.
            resumeRef?.takeIf { it.targetId == targetId && it.ref.owner == actionOwner }?.let { stored ->
                val resumed = debrid.resumePlaybackURL(stored.ref, stored.url, stored.savedAtMs)
                if (!isActionOwnerCurrent(actionOwner) || !sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
                    _playback.value = Playback.Failed(OWNER_CHANGED_MESSAGE)
                    return@launch
                }
                if (resumed.refreshed && resumed.url.isNotEmpty()) {
                    resumeRef = stored.copy(
                        url = resumed.url,
                        savedAtMs = if (resumed.url != stored.url) System.currentTimeMillis() else stored.savedAtMs,
                    )
                    lastPlayedSource = stored.source
                    _playback.value = Playback.Ready(
                        stored.playable(resumed.url, resumeMs, ref, expectedRuntimeMs()),
                    )
                    return@launch
                }
            }
            // 2) Failover among the account-confirmed-cached candidates (label-authoritative gate applied).
            val winner = resolveBestViaFailover(groups, best, debridEpisode, actionOwner)
            if (!isActionOwnerCurrent(actionOwner) || !sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) {
                _playback.value = Playback.Failed(OWNER_CHANGED_MESSAGE)
                return@launch
            }
            if (winner != null) {
                val stored = nativeDebridResumeRef(
                    targetId = targetId,
                    winner = winner,
                    fallbackSource = best,
                    savedAtMs = System.currentTimeMillis(),
                )
                resumeRef = stored
                lastPlayedSource = stored.source
                _playback.value = Playback.Ready(
                    stored.playable(winner.ref.url, resumeMs, ref, expectedRuntimeMs()),
                )
                return@launch
            }
            // 3) Fall back to the single-source resolve of the labeled best (direct / media-server / single
            //    debrid, or the confirmed-cached best the gate insisted on).
            val resolved = resolveForOwner(best, episode, actionOwner)
            if (!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())) return@launch
            _playback.value = resolved.fold(
                onSuccess = { playable ->
                    Playback.Ready(
                        playable.copy(
                            startPositionMs = if (resumeMs > 0L) resumeMs else playable.startPositionMs,
                            mediaRef = ref,
                            expectedDurationMs = expectedRuntimeMs(),
                            posterUrl = nowPlayingPoster(episode),
                            isLive = isLivePlayback(),
                            episodeTitle = episode?.title?.takeIf { it.isNotBlank() },
                        ),
                    )
                },
                onFailure = { Playback.Failed(it.message ?: "Could not start this source.") },
            )
        }
    }

    /// Race the account-confirmed-cached, resolvable candidates (raw torrents / usenet, in the list's rank
    /// order) and return the first that mints a real link and passes the label-authoritative quality gate, or
    /// null when there is nothing cached to race / every leg fails (the caller then single-resolves the
    /// labeled best). Byte-identical to today's path with no debrid key: returns before any await.
    private suspend fun resolveBestViaFailover(
        groups: List<StreamGroup>,
        best: StreamSource,
        episode: DebridResolver.Episode?,
        actionOwner: DebridOwnerToken?,
    ): DebridCoordinator.PlayableWinner? {
        val evidence = debridCacheEvidence.forOwner(
            actionOwner,
            debridKeys.currentCredentialRevision(),
        )
        if (
            actionOwner == null ||
            evidence == null ||
            !debridKeys.isCurrent(actionOwner)
        ) {
            return null
        }
        if (!debrid.hasAnyResolver && !debrid.hasUsenetResolver) return null
        if (evidence.hashes.isEmpty() && evidence.usenetUrls.isEmpty()) return null
        // Rank the candidates EXACTLY as the labeled best is picked (score + pin), de-duplicated by handle, so
        // the failover order matches the visible list.
        val ranked = StreamRanking.rankedCandidates(
            groups,
            continuity = null,
            pin = currentPin(),
            sticky = if (type == MediaType.SERIES) sourceSticky.preference(id) else null,
            providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
        )
        val candidates = ranked.mapNotNull { debridCandidateFor(it, evidence.torrentServices) }
        if (candidates.isEmpty()) return null
        return debrid.resolveFirstPlayable(
            candidates = candidates,
            episode = episode,
            cachedHashes = evidence.hashes,
            cachedUsenetURLs = evidence.usenetUrls,
            labeledBest = best,
            expectedOwner = actionOwner,
        )
    }

    private fun isActionOwnerCurrent(owner: DebridOwnerToken?): Boolean =
        debridKeys.ownerToken() == owner

    private suspend fun resolveForOwner(
        source: StreamSource,
        episode: Episode?,
        owner: DebridOwnerToken?,
    ): Result<Playable> = ownerBoundResult(
        expectedOwner = owner,
        currentOwner = debridKeys::ownerToken,
    ) {
        repo.resolve(source, episode)
    }

    private fun currentModelEpisode(): Episode? {
        if (type != MediaType.SERIES) return null
        val detail = (_meta.value as? UiState.Success)?.data ?: return null
        return detail.episodeForResolve(_selectedEpisodeId.value)
    }

    /// The title's expected runtime (ms) from the loaded catalog metadata, riding every resolved
    /// [Playable] as [Playable.expectedDurationMs] so the player's bad-source (runtime-mismatch)
    /// verdict has a ground truth to compare the file's real duration against. 0 when the meta is
    /// not loaded or carries no parseable runtime, which the player treats as "unknown" and falls
    /// back to its conservative absolute junk floor. Show-level runtime for a series (Cinemeta's
    /// per-episode runtime is not modeled on [Episode]), which is the right granularity for the
    /// "10-second file is not a 45-minute episode" check.
    private fun expectedRuntimeMs(): Long {
        val seconds = (_meta.value as? UiState.Success)?.data?.runtimeSeconds ?: return 0L
        return (seconds * 1000.0).toLong().coerceAtLeast(0L)
    }

    /// The external-sync media identity for the source about to play: the movie/show IMDb (or TMDB) id from
    /// the meta id, plus the chosen episode's season/number for a series. Null before meta loads or for an
    /// unmappable id. See [buildMediaRef].
    private fun currentMediaRef(): MediaRef? {
        val detail = (_meta.value as? UiState.Success)?.data ?: return null
        val episode = detail.videos.firstOrNull { it.id == _selectedEpisodeId.value }
        val year = detail.releaseInfo?.take(4)?.toIntOrNull()
        return buildMediaRef(type = type, metaId = id, episode = episode, title = detail.name, year = year)
    }

    /// Now-Playing artwork for the system media session / lockscreen card: the chosen episode's still
    /// (series) else the title poster. Attached on the resolved [Playable] alongside [mediaRef] so the
    /// media session ([com.vortx.android.player.PlayerMediaSession]) can decode it off-thread. Mirrors
    /// the Apple player filling `NowPlayingItem.artworkURL` from the same catalog art.
    private fun nowPlayingPoster(episode: Episode?): String? {
        val detail = (_meta.value as? UiState.Success)?.data
        return episode?.thumbnail?.takeIf { it.isNotBlank() }
            ?: detail?.poster?.takeIf { it.isNotBlank() }
    }

    /// Whether this play is a LIVE / durationless stream (a TV channel, an events feed). Rides the
    /// [Playable] so the media session withholds a bogus duration + scrub bar. Mirrors Apple
    /// `NowPlayingItem.isLive` / the `effectivelyLive` gate.
    private fun isLivePlayback(): Boolean = com.vortx.android.model.LiveTypes.contains(type.id)

    /// The best source across ALL loaded groups (the labeled "Watch" pick). Prefers [SourceListModel]'s own
    /// assembled best (ranked with the same prefs/pin/continuity the list is), falling back to ranking the
    /// published groups directly before the first assembly lands. Null when no sources resolved yet. Drives
    /// the hero Watch button's enabled state.
    fun bestSource(): StreamSource? {
        val request = sourceRequestFence.currentToken()
        val groups = (_streams.value as? UiState.Success)?.data.orEmpty()
        return bestSourceForCurrentRequest(sourceModel.state.value, request, groups) { currentGroups ->
            currentGroups.takeIf { it.isNotEmpty() }?.let {
                StreamRanking.best(
                    currentGroups,
                    continuity = lastCtx?.continuity,
                    pin = currentPin(),
                    sticky = if (type == MediaType.SERIES) sourceSticky.preference(id) else null,
                    providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
                    prefs = lastCtx?.prefs ?: StreamRanking.reading(),
                )
            }
        }
    }

    /// The engine resume position (ms) for the source about to play: the saved library `timeOffset` when
    /// it applies to the current target (a movie, or the series episode whose sources are shown), else 0
    /// (start from the top). Mirrors the Apple player reading `libraryItem.state.timeOffset` for resume,
    /// so Continue-Watching titles resume where they were left off.
    private fun resumeOffsetMs(): Long {
        val lib = (_meta.value as? UiState.Success)?.data?.libraryItem ?: return 0L
        if (lib.timeOffsetMs <= 0L) return 0L
        val target = _selectedEpisodeId.value
        return if (target == null || lib.videoId == null || lib.videoId == target) lib.timeOffsetMs else 0L
    }

    /// Whether the source about to play has a saved resume position (DET-14): true only when
    /// [resumeOffsetMs] would seek forward, so the "Play from start" secondary action is offered for a
    /// resumed title and hidden for a fresh one. Read-only; mirrors Apple's `movieResumeSeconds != nil`.
    fun resumeAvailable(): Boolean = resumeOffsetMs() > 0L

    fun clearPlayback() {
        _playback.value = Playback.Idle
    }

    fun clearMutationError() {
        _mutationError.value = null
    }

    // ---- Up Next auto-advance ----

    /// The episode that FOLLOWS the current play target in cross-season order
    /// ([orderedBySeasonEpisode]: a season's last episode rolls into the next season's first), or null
    /// for a movie, before an episode is selected, or at the very last episode. The shell reads this
    /// when a playback ends to decide whether to offer Up Next instead of exiting to Detail.
    fun nextEpisode(): Episode? {
        if (type != MediaType.SERIES) return null
        val detail = (_meta.value as? UiState.Success)?.data ?: return null
        val currentId = _selectedEpisodeId.value ?: return null
        val ordered = detail.videos.orderedBySeasonEpisode
        val idx = ordered.indexOfFirst { it.id == currentId }
        if (idx < 0 || idx + 1 >= ordered.size) return null
        return ordered[idx + 1]
    }

    /// Auto-advance to [nextEpisode]: select it and play its best-ranked source the moment its add-on
    /// groups land, via the same consume-once latch a Smart-Source episode tap uses -- but armed
    /// UNCONDITIONALLY (an Up Next the viewer accepted, or let count down, must play whether or not the
    /// Smart Source setting is on) and carrying the just-finished play's quality signature + bingeGroup
    /// so the ranking's continuity/binge bonuses keep the binge on the same release family. Resolution
    /// posts through [playback] exactly like a manual play; the shell's Up Next layer collects
    /// Ready/Failed from there. No-op when there is no next episode or a resolve is already running.
    /**
     * PLR-8 next-episode PRELOAD: pre-fetch and rank the NEXT episode's sources OFF the live playback fence,
     * caching the best source by episode id so an eventual auto-advance skips the source-assembly wait.
     *
     * Non-disruptive by construction: it uses a direct [CatalogRepository.streams] fetch (a one-shot that
     * returns its own result and never feeds the reactive [_streams] / [sourceRequestFence] the live episode
     * owns) and writes ONLY the [warmNextSourceByEpisode] cache. It resolves nothing (no debrid unlock, no
     * torrent warm-up), so it is cheap and cannot contend with the playing stream. Fail-soft and idempotent
     * per episode. Returns true when a source was cached. Driven by the shell's [NextEpisodePreloadPolicy].
     */
    suspend fun warmNextEpisode(episodeId: String): Boolean {
        if (type != MediaType.SERIES) return false
        if (warmNextSourceByEpisode?.first == episodeId) return true
        val detail = (_meta.value as? UiState.Success)?.data ?: return false
        val target = detail.videos.firstOrNull { it.id == episodeId } ?: return false
        val groups = repo.streams(
            type = type,
            id = id,
            episodeId = target.id,
            rememberedQuality = lastPlayedSource?.let(StreamRanking::qualityLabel),
            wantedAddon = sourceSticky.preference(id)?.addon,
        ).getOrNull()?.takeIf { list -> list.any { it.streams.isNotEmpty() } } ?: return false
        val best = StreamRanking.best(
            groups = groups,
            continuity = lastPlayedSource?.let(StreamRanking::signature),
            binge = lastPlayedSource?.bingeGroup,
            pin = currentPin(),
            sticky = sourceSticky.preference(id),
            providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
            prefs = lastCtx?.prefs ?: StreamRanking.reading(),
        ) ?: return false
        warmNextSourceByEpisode = episodeId to best
        return true
    }

    fun playNextEpisode() {
        if (_playback.value is Playback.Resolving) return
        val next = nextEpisode() ?: return
        // Consume a warm-cached best source for this episode (PLR-8): resolve the pre-ranked source right
        // away and skip the source-assembly "Starting..." wait. Any miss falls through to the cold path
        // below. The fence is (re)begun for the target so play()'s token + episode identity are correct;
        // the reactive assembly still runs to populate the new episode's in-player source list, but playback
        // no longer waits on it.
        val warm = warmNextSourceByEpisode?.takeIf { it.first == next.id }?.second
        warmNextSourceByEpisode = null
        if (warm != null) {
            _selectedSeason.value = next.season
            _selectedEpisodeId.value = next.id
            startSourceLoad(next.id)
            playAutomatically(warm)
            return
        }
        pendingAdvanceHint = lastPlayedSource?.let { StreamRanking.signature(it) to it.bingeGroup }
        // Keep the episode browser in step so backing out of the advanced play shows the RIGHT season.
        _selectedSeason.value = next.season
        if (_selectedEpisodeId.value == next.id) {
            // Already scoped to the target (a countdown double-fire, or a re-offer): play what is loaded.
            pendingAdvanceHint = null
            playBest()
            return
        }
        _selectedEpisodeId.value = next.id
        pendingAutoPick = true
        startSourceLoad(next.id)
    }

    // ---- Bad-source retry ladder (the trust fix) ----
    //
    // "The file ended" must never mean "the episode was watched": when the player judges the live
    // source BAD (engine error, stall watchdog, or the runtime-mismatch verdict -- a ~10s junk file
    // standing in for a removed episode), the shell calls [retryNextSource] and the ladder tries the
    // NEXT distinct source from the SAME ranked list the visible source rows use, carrying the failed
    // play's continuity/binge hints so the retry stays on the closest release family. After
    // [MAX_SOURCE_ATTEMPTS] distinct sources fail for the same play target, it stops and the shell
    // surfaces manual selection ([manualSourceOptions]) instead: never silently give up, never advance.

    /// Failed playable handles per play target (episode id, or the movie id) for this ViewModel's
    /// lifetime, so a retry never re-picks a source that already failed this session and the ladder's
    /// attempt cap is per EPISODE, not per player instance. Handle = `id.substringBefore('#')`, the
    /// same identity [StreamRanking]'s de-dup and the resolve paths key on.
    private val failedHandlesByTarget = HashMap<String, MutableSet<String>>()

    /// Record the just-failed play (the last source this ViewModel resolved) against the current play
    /// target and start the next-ranked source, WITHOUT bouncing the viewer out of the player: the
    /// resolve posts through [playback] exactly like a manual play and the shell swaps the player's
    /// [Playable] on Ready. Returns false when the ladder is exhausted ([MAX_SOURCE_ATTEMPTS] distinct
    /// sources failed) or no untried candidate exists, in which case the caller must surface MANUAL
    /// selection. (The hive-mind failure-report hook (#80) would attach here: target id + failed
    /// handle + attempt count are all in scope. Not built in this change.)
    fun retryNextSource(resumePositionMs: Long? = null): Boolean {
        val targetId = _selectedEpisodeId.value ?: id
        val failed = failedHandlesByTarget.getOrPut(targetId) { mutableSetOf() }
        // No record of what just failed means the ledger cannot grow and the attempt cap could never
        // trip: surface manual selection rather than risk retrying the same dead source forever.
        val failedSource = lastPlayedSource ?: return false
        failed.add(handleOf(failedSource))
        ProviderHealth.noteFailure(failedSource.addon)
        if (failed.size >= MAX_SOURCE_ATTEMPTS) return false
        val groups = (_streams.value as? UiState.Success)?.data ?: return false
        val ctx = lastCtx ?: return false
        // Ranked EXACTLY as the visible list / auto-pick ranks (score + continuity + binge + pin +
        // the user's filter prefs), so the retry order matches what the viewer would pick by hand,
        // hinted toward the failed play's release family (same quality tier, same binge group).
        val ranked = StreamRanking.rankedCandidates(
            groups,
            continuity = StreamRanking.signature(failedSource),
            binge = failedSource.bingeGroup,
            pin = currentPin(),
            sticky = if (type == MediaType.SERIES) sourceSticky.preference(id) else null,
            providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
            prefs = ctx.prefs,
        )
        val next = ranked.firstOrNull { handleOf(it) !in failed } ?: return false
        playAutomatically(next, resumePositionMs)
        return true
    }

    /// The ranked source list for the shell's manual-pick fallback (shown after the auto-retry ladder
    /// exhausts): best-first, de-duplicated, ranked with the same prefs/pin as the detail rows.
    /// Deliberately NOT filtered by the failed set -- the viewer may knowingly re-try one -- and capped
    /// so the overlay stays scannable. Empty before sources load (the shell then exits to Detail).
    fun playerSourceOptions(limit: Int = PLAYER_SOURCE_LIMIT): List<StreamSource> =
        rankedSourceOptions(limit)

    /** Episodes offered inside the player: only the playing target's current season, in episode order. */
    fun playerEpisodeOptions(): List<Episode> {
        if (type != MediaType.SERIES) return emptyList()
        val detail = (_meta.value as? UiState.Success)?.data ?: return emptyList()
        val current = detail.videos.firstOrNull { it.id == _selectedEpisodeId.value } ?: return emptyList()
        return detail.videos
            .asSequence()
            .filter { it.season == current.season }
            .sortedWith(compareBy<Episode> { it.episode }.thenBy { it.id })
            .toList()
    }

    /** Best stream per visible resolution bucket, using the current assembled target only. */
    fun playerQualityOptions(): List<Pair<String, StreamSource>> {
        val request = sourceRequestFence.currentToken() ?: return emptyList()
        val state = sourceModel.state.value
        if (state.requestGeneration == request.generation && state.streamId == request.targetId) {
            return state.resolutionOptions
        }
        val groups = (_streams.value as? UiState.Success)?.data ?: return emptyList()
        return StreamRanking.resolutionOptions(groups)
    }

    /** The exact source whose resolved [Playable] is currently mounted in the player. */
    fun currentPlayerSource(): StreamSource? = lastPlayedSource

    fun manualSourceOptions(limit: Int = MANUAL_PICK_LIMIT): List<StreamSource> =
        rankedSourceOptions(limit)

    private fun rankedSourceOptions(limit: Int): List<StreamSource> {
        val groups = (_streams.value as? UiState.Success)?.data ?: return emptyList()
        val prefs = lastCtx?.prefs
        val sticky = if (type == MediaType.SERIES) sourceSticky.preference(id) else null
        val ranked = if (prefs != null) {
            StreamRanking.rankedCandidates(
                groups,
                continuity = null,
                pin = currentPin(),
                sticky = sticky,
                providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
                prefs = prefs,
            )
        } else {
            StreamRanking.rankedCandidates(
                groups,
                continuity = null,
                pin = currentPin(),
                sticky = sticky,
                providerPenalty = { addon -> ProviderHealth.penaltyActive(addon) },
            )
        }
        return ranked.take(limit)
    }

    /// The playable-handle identity used by the failed-source ledger: the id up to the first '#'
    /// (mirrors [StreamRanking]'s private handleOf and the resolve/dedup convention documented on
    /// [CACHED_ID_SUFFIX]).
    private fun handleOf(source: StreamSource): String = source.id.substringBefore('#')

    // ---- S05: resume targeting ----

    /// The hero Watch/Resume target for a series -- the in-progress episode (a saved position, not yet
    /// watched) if one exists, else the first unwatched episode, else the first episode. Ported from
    /// `SourcesTV/DetailView.swift`'s `seriesPrimaryEpisode`. Returns null for a movie or before meta
    /// has loaded. The `Boolean` is true for a genuine RESUME (append the saved timecode / label
    /// "Resume"), false for a fresh "Play".
    fun primaryEpisode(): Pair<Episode, Boolean>? {
        val detail = (_meta.value as? UiState.Success)?.data ?: return null
        return primaryEpisodeOf(detail)
    }

    private fun primaryEpisodeOf(detail: MetaDetail): Pair<Episode, Boolean>? {
        if (detail.videos.isEmpty()) return null
        val sorted = sortedEpisodes(detail.videos)
        val lib = detail.libraryItem
        if (lib != null && lib.timeOffsetMs > 0 && lib.videoId != null) {
            val resumeVideo = sorted.firstOrNull { it.id == lib.videoId }
            if (resumeVideo != null && resumeVideo.id !in detail.watchedVideoIds) return resumeVideo to true
        }
        val next = sorted.firstOrNull { it.id !in detail.watchedVideoIds }
        if (next != null) return next to false
        return sorted.first() to false
    }

    // ---- S05: watched-state + library mutations ----
    //
    // Every mutation swaps [_meta] with the engine's freshly re-pulled [MetaDetail]
    // (see [CatalogRepository]'s S05 doc comment) so ticks/progress/the library chip update live; a
    // failure is surfaced via [mutationError] instead of clobbering the loaded page with [UiState.Error].

    /// Mark the whole title (movie, or every episode of a series) watched/unwatched.
    ///
    /// ROOT CAUSE of the device-round "first invocation did nothing" bug: the engine's aggregate
    /// `MarkAsWatched(bool)` action (see `LibraryItem::mark_as_watched` in the vendored stremio-core
    /// crate, `types/library/library_item.rs`) only flips `timesWatched`/`lastWatched` on the library
    /// item -- it NEVER touches the per-video `WatchedBitField` a series' episode ticks
    /// ([MetaDetail.watchedVideoIds]) are derived from. That bitfield is written ONLY by
    /// `MarkVideoAsWatched`/`MarkSeasonAsWatched`. So dispatching `MarkAsWatched(true)` on a series
    /// silently updated the (invisible) aggregate flag while every episode tick stayed exactly as it
    /// was -- indistinguishable from "did nothing" to the user watching the episode list. Unwatching
    /// already iterated per-video (see the loop below) for the same reason Apple's `CoreBridge.markWatched`
    /// documents, so only the `true` branch was affected.
    ///
    /// Fix: BOTH directions iterate every video, every season (sorted, deterministic order -- not the
    /// engine's raw JSON order, which is not guaranteed stable) via `MarkVideoAsWatched`, so every tick
    /// updates the instant this returns; then re-dispatch the aggregate `MarkAsWatched` too (best-effort)
    /// so the movie-style `timesWatched`/resume-target metadata the hero button reads stays in sync. Each
    /// dispatch is a synchronous engine call immediately re-read (see [CatalogRepository]'s S05 doc
    /// comment), so the loop can never race itself -- the final [applyMutation] snapshot already reflects
    /// every prior step in the same sequence.
    fun setWatched(isWatched: Boolean) {
        val current = (_meta.value as? UiState.Success)?.data ?: return
        viewModelScope.launch {
            val result = if (current.videos.isEmpty()) {
                repo.setWatched(type, id, isWatched)
            } else {
                var last: Result<MetaDetail> = Result.success(current)
                for (video in sortedEpisodes(current.videos)) {
                    last = repo.setVideoWatched(
                        type = type,
                        id = id,
                        videoId = video.id,
                        season = video.season.takeIf { it > 0 },
                        episode = video.episode.takeIf { it > 0 },
                        isWatched = isWatched,
                    )
                    if (last.isFailure) break
                }
                if (last.isSuccess) last = repo.setWatched(type, id, isWatched)
                last
            }
            applyMutation(result)
        }
    }

    /// Mark every episode of [season] watched/unwatched.
    fun setSeasonWatched(season: Int, isWatched: Boolean) {
        viewModelScope.launch {
            applyMutation(repo.setSeasonWatched(type, id, season, isWatched))
        }
    }

    /// Mark one episode watched/unwatched (the per-episode long-press menu / checkmark toggle).
    fun setVideoWatched(episode: Episode, isWatched: Boolean) {
        viewModelScope.launch {
            applyMutation(
                repo.setVideoWatched(
                    type = type,
                    id = id,
                    videoId = episode.id,
                    season = episode.season.takeIf { it > 0 },
                    episode = episode.episode.takeIf { it > 0 },
                    isWatched = isWatched,
                ),
            )
        }
    }

    /// Toggle the open title's Add-to-Library state, reading the current state off the just-loaded
    /// [MetaDetail.libraryItem] so the chip always reflects the engine's own truth.
    fun toggleLibrary() {
        val current = (_meta.value as? UiState.Success)?.data ?: return
        val inLibrary = current.libraryItem?.savedToLibrary == true
        viewModelScope.launch {
            val result = if (inLibrary) {
                repo.removeFromLibrary(type, id)
            } else {
                repo.addToLibrary(type, id, current.name, current.poster)
            }
            applyMutation(result)
        }
    }

    /** Toggle the separate profile-local want-to-watch ledger without mutating the account library. */
    fun toggleWatchlist() {
        val current = (_meta.value as? UiState.Success)?.data ?: return
        viewModelScope.launch {
            watchlistStore.toggle(
                MetaItem(
                    id = current.id,
                    type = current.type,
                    name = current.name,
                    poster = current.poster,
                ),
            )
        }
    }

    private fun applyMutation(result: Result<MetaDetail>) {
        result.fold(
            onSuccess = { _meta.value = UiState.Success(it) },
            onFailure = { _mutationError.value = it.message ?: "Couldn't save that change." },
        )
    }

    private fun sortedEpisodes(videos: List<Episode>): List<Episode> =
        videos.sortedWith(compareBy({ it.season }, { it.episode }, { it.id }))

    /// Tear down the assembly pipeline + contributor lanes when the screen goes away. [SourceListModel.close]
    /// stops the coalescer (it runs on [viewModelScope], which is cancelled anyway, but the contributors own
    /// their OWN scopes and must be closed explicitly to cancel any in-flight TorBox / Singularity fetch).
    override fun onCleared() {
        sourceSwitchCommitGate.invalidate()
        super.onCleared()
        sourceModel.close()
        torbox.close()
        singularity.close()
    }

    private companion object {
        const val OWNER_CHANGED_MESSAGE = "The active VortX account changed. Try again."

        /// How many DISTINCT sources the bad-source ladder may burn per play target before it stops
        /// auto-retrying and the shell surfaces manual selection (the CEO's "after 3 failures, ask").
        const val MAX_SOURCE_ATTEMPTS = 3

        /// Manual-pick overlay cap: enough to always include every realistic quality tier without
        /// rendering a thousand-row list inside the player.
        const val MANUAL_PICK_LIMIT = 30

        /** Maximum ranked alternates kept in the eager in-player source sheet. */
        const val PLAYER_SOURCE_LIMIT = 60

        /** Contributor settlement budget for an accepted Up Next action. Always bounded. */
        const val AUTO_NEXT_ASSEMBLY_DEADLINE_MS = 4_000L

        /** Same bounded unified-source settlement used by an explicit in-player episode pick. */
        const val EPISODE_SWITCH_ASSEMBLY_DEADLINE_MS = 4_000L

        /** Maximum wait for the target episode's first non-empty add-on source wave. */
        const val EPISODE_SWITCH_SOURCE_DEADLINE_MS = 15_000L

        /// The text marker folded into an account-cached source's description so the text-based [StreamRanking]
        /// lights the cache badge + applies the +cache bonus (it looks for a bolt / "cached").
        const val CACHED_MARKER = "⚡ Cached"

        /// A cache-busting suffix appended to a decorated source's id (the score/quality caches key on the id).
        /// It carries no '#', so `id.substringBefore('#')` -- the handle the resolve + dedup paths read -- is
        /// unchanged.
        const val CACHED_ID_SUFFIX = "\u0000cached"
    }
}

/// Playback request state for the detail page. Resolving covers the engine round-trip (streaming
/// server hand-off / debrid unlock) so the UI shows progress rather than freezing.
sealed interface Playback {
    data object Idle : Playback
    data object Resolving : Playback
    data class Ready(val playable: Playable) : Playback
    data class Failed(val message: String) : Playback
}

private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)
