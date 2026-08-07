package com.vortx.android.ui.viewmodel

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingDismissal
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.data.HomeUpdate
import com.vortx.android.home.BecauseYouWatchedModel
import com.vortx.android.home.CollectionsHubBrowseState
import com.vortx.android.home.CollectionsHubCategory
import com.vortx.android.home.CollectionsHubModel
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.HomeCatalogLayout
import com.vortx.android.home.HomeRailPreferences
import com.vortx.android.home.HomeRailSurface
import com.vortx.android.home.ImportedCatalogs
import com.vortx.android.home.ReleaseCalendarModel
import com.vortx.android.home.ReleaseCalendarOwner
import com.vortx.android.home.ReleaseCalendarRefresh
import com.vortx.android.home.SimklRailsModel
import com.vortx.android.home.TopPicksModel
import com.vortx.android.home.TraktRailsModel
import com.vortx.android.home.importedCatalogRails
import com.vortx.android.home.upcomingMetaBases
import com.vortx.android.home.withBecauseYouWatchedRail
import com.vortx.android.home.withExternalWatchlistRails
import com.vortx.android.home.withImportedCatalogRails
import com.vortx.android.home.withReleaseCalendarRails
import com.vortx.android.home.withTopPicksRail
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.library.WatchlistStore
import com.vortx.android.mediaserver.MediaServerCatalogsModel
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.mediaserver.withMediaServerRails
import com.vortx.android.model.AuthState
import com.vortx.android.model.Catalog
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.search.SearchHistoryStore
import com.vortx.android.ui.UiState
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/// Maps a repository [Result] to a [UiState], turning a thrown/failed add-on call into a visible
/// error instead of an empty screen. Shared by every catalog ViewModel.
private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)

internal data class ReleaseCalendarBoundary(
    val profileId: String,
    val accountId: String,
)

/** Keeps the release-cache generation stable across noisy ctx ticks and advances only on owner changes. */
internal class ReleaseCalendarOwnerTracker(initialBoundary: ReleaseCalendarBoundary) {
    private var boundary = initialBoundary
    private var generation = 0L

    fun ownerFor(nextBoundary: ReleaseCalendarBoundary): ReleaseCalendarOwner {
        if (nextBoundary != boundary) {
            boundary = nextBoundary
            generation += 1
        }
        return ReleaseCalendarOwner(nextBoundary.profileId, generation)
    }
}

private fun CatalogRepository.releaseCalendarAccountId(): String = when (
    val auth = (this as? AuthRepository)?.authState?.value
) {
    is AuthState.SignedIn -> "signed-in:${auth.uid ?: auth.email ?: "unknown"}"
    AuthState.SignedOut -> "signed-out"
    null -> "account-unavailable"
}

/// Home: Continue Watching + add-on catalog rails. Collects the repository's CONTINUOUS
/// [CatalogRepository.homeUpdates] stream for the ViewModel's lifetime (not a one-shot load): the
/// engine settles the board add-on by add-on, so rails must appear incrementally as each answers,
/// and a sign-in/sign-out mid-session must swap the rail set live -- both of which a single
/// `home()` call can never do (the S03 device round showed exactly that: rails empty forever).
///
/// State contract: Loading (shimmer) until the FIRST non-empty rail set arrives; then Success,
/// updated in place on every later change. If nothing arrives within [EMPTY_TIMEOUT_MS], Error with
/// Retry -- never a silent black screen -- but collection continues, so data landing late still
/// replaces the error.
internal class HomeUpdateReducer {
    private var latestGeneration = Long.MIN_VALUE
    private var latestSequence = Long.MIN_VALUE
    private var latestProfileId: String? = null

    fun reduce(update: HomeUpdate): UiState<List<Catalog>>? {
        if (update.generation < latestGeneration) return null
        if (update.generation == latestGeneration && update.sequence < latestSequence) return null
        if (
            update.generation == latestGeneration &&
            latestProfileId != null &&
            latestProfileId != update.profileId
        ) return null

        latestGeneration = update.generation
        latestSequence = update.sequence
        latestProfileId = update.profileId
        return when {
            update.authoritative -> UiState.Success(update.rows)
            update.rows.isNotEmpty() -> UiState.Success(update.rows)
            else -> null
        }
    }
}

class HomeViewModel internal constructor(
    private val repo: CatalogRepository,
    private val railPreferences: HomeRailPreferences? = null,
    private val railSurface: HomeRailSurface = HomeRailSurface.PHONE,
    private val watchlistStore: WatchlistStore? = null,
    private val traktRails: TraktRailsModel = TraktRailsModel(),
    private val simklRails: SimklRailsModel = SimklRailsModel(),
    private val becauseYouWatched: BecauseYouWatchedModel = BecauseYouWatchedModel(),
    private val mediaServerCatalogs: MediaServerCatalogsModel = MediaServerCatalogsModel(),
    private val importedCatalogs: ImportedCatalogs? = null,
    private val activeProfileId: () -> String = {
        ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID
    },
    private val dismissalDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val scopeOverride: CoroutineScope? = null,
    private val confirmationTimeoutMs: Long = CONFIRMATION_TIMEOUT_MS,
    private val confirmationPollMs: Long = CONFIRMATION_POLL_MS,
    private val collectionsHub: CollectionsHubModel? = null,
) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<Catalog>>>(UiState.Loading)
    val state: StateFlow<UiState<List<Catalog>>> = _state.asStateFlow()
    private val _contentOwnerGeneration = MutableStateFlow(0L)
    val contentOwnerGeneration: StateFlow<Long> = _contentOwnerGeneration.asStateFlow()
    val homeCatalogLayout: StateFlow<HomeCatalogLayout> = railPreferences?.state
        ?.map { it.catalogLayout }
        ?.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = railPreferences?.state?.value?.catalogLayout ?: HomeCatalogLayout.RAILS,
        ) ?: MutableStateFlow(HomeCatalogLayout.RAILS).asStateFlow()
    internal val collections: StateFlow<CollectionsHubSnapshot> = collectionsHub?.snapshot
        ?: MutableStateFlow(CollectionsHubSnapshot())
    internal val collectionBrowse: StateFlow<CollectionsHubBrowseState> = collectionsHub?.browse
        ?: MutableStateFlow(CollectionsHubBrowseState())

    private val scope: CoroutineScope get() = scopeOverride ?: viewModelScope
    private var collectJob: Job? = null
    private var personalizedJob: Job? = null
    private var baseRows: List<Catalog> = emptyList()
    private var topPicksItems: List<MetaItem> = emptyList()
    private var sourceHasRows = false
    private var upcomingEpisodes: List<MetaItem> = emptyList()
    private var upcomingMovies: List<MetaItem> = emptyList()
    private var traktWatchlist: List<MetaItem> = emptyList()
    private var simklWatchlist: List<MetaItem> = emptyList()
    private var becauseYouWatchedRail: Catalog? = null
    private var mediaServerRails: List<Catalog> = emptyList()
    private var importedRails: List<Catalog> = importedCatalogs?.catalogs?.value
        ?.let(::importedCatalogRails).orEmpty()
    private val topPicks = TopPicksModel()
    private val releaseCalendar = ReleaseCalendarModel()
    private val releaseOwnerTracker = ReleaseCalendarOwnerTracker(currentReleaseBoundary())
    private val pendingContinueWatchingDismissals = linkedSetOf<ContinueWatchingDismissal>()
    private val continueWatchingRollbacks = mutableMapOf<ContinueWatchingDismissal, ContinueWatchingRollback>()
    private var renderedOwner: ContinueWatchingOwner? = null
    private var latestAuthoritativeRows: List<Catalog>? = null

    init {
        load()
        collectionsHub?.let { hub ->
            scope.launch {
                hub.settingsChanges.collectLatest { hub.load() }
            }
        }
        scope.launch {
            repo.ctxUpdates().drop(1).collectLatest {
                watchlistStore?.reload()
                refreshPersonalizedRails()
            }
        }
        (repo as? AuthRepository)?.let { authRepository ->
            scope.launch {
                authRepository.authState.collectLatest {
                    // Engine auth publication can follow its ctx tick. Re-sample the stable account
                    // identity here so that boundary invalidation cannot lose that race.
                    refreshPersonalizedRails()
                }
            }
        }
        ProfileStore.sharedOrNull()?.let { profileStore ->
            scope.launch {
                profileStore.activeProfile
                    .drop(1)
                    .collectLatest { refreshPersonalizedRails() }
            }
        }
        watchlistStore?.let { store ->
            scope.launch {
                store.items.drop(1).collectLatest { refreshPersonalizedRails() }
            }
        }
        scope.launch {
            TraktAuth.sessionBoundary.drop(1).collectLatest {
                traktRails.clear()
                traktWatchlist = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        scope.launch {
            SIMKLAuth.sessionBoundary.drop(1).collectLatest {
                simklRails.clear()
                simklWatchlist = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        scope.launch {
            MediaServerRepository.configurationBoundary.drop(1).collectLatest {
                mediaServerCatalogs.clear()
                mediaServerRails = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        importedCatalogs?.let { registry ->
            scope.launch {
                registry.catalogs.drop(1).collectLatest { catalogs ->
                    importedRails = importedCatalogRails(catalogs)
                    publishHome()
                }
            }
        }
    }

    fun load() {
        collectJob?.cancel()
        personalizedJob?.cancel()
        baseRows = emptyList()
        topPicksItems = emptyList()
        sourceHasRows = false
        upcomingEpisodes = emptyList()
        upcomingMovies = emptyList()
        traktWatchlist = emptyList()
        simklWatchlist = emptyList()
        becauseYouWatchedRail = null
        mediaServerRails = emptyList()
        pendingContinueWatchingDismissals.clear()
        continueWatchingRollbacks.clear()
        latestAuthoritativeRows = null
        renderedOwner = null
        _state.value = UiState.Loading
        collectJob = scope.launch {
            val reducer = HomeUpdateReducer()
            // Watchdog: an engine that produces no rails at all (no network AND no cache) must show
            // the composed error card, never shimmer/black forever. A child job, so cancel-on-reload
            // covers it too; it no-ops once real data has landed.
            launch {
                delay(EMPTY_TIMEOUT_MS)
                if (_state.value is UiState.Loading) {
                    _state.value = UiState.Error("Couldn't load your catalogs. Check your connection and try again.")
                }
            }
            val homeUpdates = railPreferences?.let { preferences ->
                repo.homeUpdates().combine(preferences.state) { update, _ ->
                    update.rows.isNotEmpty() to update
                }
            } ?: repo.homeUpdates().map { snapshot -> snapshot.rows.isNotEmpty() to snapshot }
            homeUpdates
                .catch { error ->
                    _state.value = UiState.Error(error.message ?: "Something went wrong loading your add-ons.")
                }
                .collect { (hasRows, update) ->
                    val reduced = reducer.reduce(update) ?: return@collect
                    val owner = update.owner
                    val previousOwner = renderedOwner
                    // A queued emission remains stamped with the owner/revision it was produced under. Once
                    // a newer revision rendered, never let an older owner overwrite it.
                    if (previousOwner != null && owner.revision < previousOwner.revision) return@collect
                    if (previousOwner != null &&
                        owner.revision == previousOwner.revision &&
                        owner != previousOwner
                    ) {
                        return@collect
                    }
                    if (owner != previousOwner) {
                        pendingContinueWatchingDismissals.clear()
                        continueWatchingRollbacks.clear()
                        latestAuthoritativeRows = null
                        renderedOwner = owner
                        clearOwnerPersonalizedRows()
                        if (update.rows.isEmpty() && !update.authoritative) _state.value = UiState.Loading
                    }
                    val rows = (reduced as UiState.Success).data
                    if (update.authoritative) {
                        pendingContinueWatchingDismissals.clear()
                        continueWatchingRollbacks.clear()
                    }
                    this@HomeViewModel.sourceHasRows = update.authoritative || hasRows
                    baseRows = rows
                    latestAuthoritativeRows = rows
                    publishHome()
                    refreshPersonalizedRails()
                }
        }
        publishHome()
        refreshPersonalizedRails()
        scope.launch { collectionsHub?.load() }
    }

    internal fun openCollection(target: CollectionsHubTarget) {
        viewModelScope.launch { collectionsHub?.open(target) }
    }

    fun retryCollectionsHub() {
        viewModelScope.launch { collectionsHub?.load() }
    }

    fun retryCollection() {
        viewModelScope.launch { collectionsHub?.retry() }
    }

    internal fun selectCollectionCategory(category: CollectionsHubCategory) {
        viewModelScope.launch { collectionsHub?.selectCategory(category) }
    }

    fun loadMoreCollection() {
        viewModelScope.launch { collectionsHub?.loadMore() }
    }

    fun closeCollection() {
        collectionsHub?.closeBrowse()
    }

    override fun onCleared() {
        collectionsHub?.close()
        super.onCleared()
    }

    private fun refreshPersonalizedRails() {
        val owner = currentReleaseOwner()
        if (applyReleaseCalendar(releaseCalendar.activate(owner))) publishHome()
        val rows = baseRows
        personalizedJob?.cancel()
        personalizedJob = scope.launch {
            val libraryWork = async { repo.library() }
            val addonsWork = async { repo.installedAddons() }
            val libraryResult = libraryWork.await()
            val library = libraryResult.getOrNull()?.items.orEmpty()
            val continueWatching = rows.firstOrNull { it.id == "continue" }?.items.orEmpty()
            val watchlist = watchlistStore?.items?.value.orEmpty()
            val topPicksWork = async {
                topPicks.refresh(continueWatching, library) {
                    topPicksItems = emptyList()
                    publishHome()
                }
            }
            val becauseWork = async {
                becauseYouWatched.refresh(continueWatching, library) {
                    becauseYouWatchedRail = null
                    publishHome()
                }
            }
            val traktWork = async { traktRails.refresh() }
            val simklWork = async { simklRails.refresh() }
            val mediaServerWork = async { mediaServerCatalogs.refresh() }
            val releaseWork = async {
                val addonsResult = addonsWork.await()
                if (libraryResult.isFailure || addonsResult.isFailure) return@async null
                releaseCalendar.refresh(
                    owner = owner,
                    library = library,
                    watchlist = watchlist,
                    metaBases = upcomingMetaBases(addonsResult.getOrThrow()),
                    onInvalidated = { invalidated ->
                        if (applyReleaseCalendar(invalidated)) publishHome()
                    },
                )
            }
            val refreshed = topPicksWork.await()
            val because = becauseWork.await()
            val upcoming = releaseWork.await()
            val trakt = traktWork.await()
            val simkl = simklWork.await()
            val media = mediaServerWork.await()
            if (owner != currentReleaseOwner()) return@launch
            if (refreshed.changed) {
                topPicksItems = refreshed.items
            }
            val upcomingChanged = upcoming?.let(::applyReleaseCalendar) == true
            if (because.changed) becauseYouWatchedRail = because.rail
            if (media.changed) mediaServerRails = media.rails
            val externalChanged = traktWatchlist != trakt.items || simklWatchlist != simkl.items
            traktWatchlist = trakt.items
            simklWatchlist = simkl.items
            if (
                refreshed.changed || because.changed || media.changed || upcomingChanged ||
                trakt.changed || simkl.changed || externalChanged
            ) {
                publishHome()
            }
        }
    }

    private fun currentReleaseBoundary() = ReleaseCalendarBoundary(
        profileId = activeProfileId(),
        accountId = repo.releaseCalendarAccountId(),
    )

    private fun currentReleaseOwner(): ReleaseCalendarOwner =
        releaseOwnerTracker.ownerFor(currentReleaseBoundary()).also { owner ->
            _contentOwnerGeneration.value = owner.generation
        }

    private fun applyReleaseCalendar(refresh: ReleaseCalendarRefresh): Boolean {
        val changed = upcomingEpisodes != refresh.episodes || upcomingMovies != refresh.movies
        upcomingEpisodes = refresh.episodes
        upcomingMovies = refresh.movies
        return changed
    }

    /** Clear every owner-derived client rail before the replacement owner can render. */
    private fun clearOwnerPersonalizedRows() {
        personalizedJob?.cancel()
        topPicksItems = emptyList()
        upcomingEpisodes = emptyList()
        upcomingMovies = emptyList()
        traktWatchlist = emptyList()
        simklWatchlist = emptyList()
        becauseYouWatchedRail = null
        mediaServerRails = emptyList()
    }

    private fun publishHome() {
        val hasClientRows = topPicksItems.isNotEmpty() || becauseYouWatchedRail != null ||
            traktWatchlist.isNotEmpty() || simklWatchlist.isNotEmpty() || mediaServerRails.isNotEmpty() ||
            importedRails.isNotEmpty() || upcomingEpisodes.isNotEmpty() || upcomingMovies.isNotEmpty()
        if (!sourceHasRows && !hasClientRows) return
        val topRows = withTopPicksRail(baseRows, topPicksItems)
        val becauseRows = withBecauseYouWatchedRail(topRows, becauseYouWatchedRail)
        val externalRows = withExternalWatchlistRails(becauseRows, traktWatchlist, simklWatchlist)
        val serverRows = withMediaServerRails(externalRows, mediaServerRails)
        val importedRows = withImportedCatalogRails(serverRows, importedRails)
        val enriched = withReleaseCalendarRails(importedRows, upcomingEpisodes, upcomingMovies)
        val rows = railPreferences?.let { preferences ->
            preferences.arrange(enriched, railSurface, preferences.state.value)
        } ?: enriched
        val visibleRows = renderedOwner?.let { owner ->
            withoutContinueWatchingItems(rows, pendingContinueWatchingDismissals, owner)
        } ?: rows
        _state.value = UiState.Success(visibleRows)
    }

    fun removeFromContinueWatching(item: MetaItem) {
        val owner = renderedOwner ?: return
        val target = ContinueWatchingDismissal(owner, item.type, item.id)
        if (!pendingContinueWatchingDismissals.add(target)) return
        val current = (_state.value as? UiState.Success)?.data
        if (current != null) {
            captureContinueWatchingRollback(current, target)?.let { continueWatchingRollbacks[target] = it }
            publishHome()
        }
        scope.launch {
            val confirmed = withContext(dismissalDispatcher) {
                val removed = repo.removeFromContinueWatching(target)
                removed.isSuccess && awaitContinueWatchingAbsent(
                    target = target,
                    snapshot = { repo.continueWatchingSnapshot(owner) },
                    timeoutMs = confirmationTimeoutMs,
                    pollMs = confirmationPollMs,
                )
            }
            if (renderedOwner != owner) {
                pendingContinueWatchingDismissals.remove(target)
                continueWatchingRollbacks.remove(target)
            } else if (confirmed) {
                pendingContinueWatchingDismissals.remove(target)
                continueWatchingRollbacks.remove(target)
                latestAuthoritativeRows = latestAuthoritativeRows?.let {
                    withoutContinueWatchingItems(it, setOf(target), owner)
                }
                baseRows = withoutContinueWatchingItems(baseRows, setOf(target), owner)
                publishHome()
            } else if (pendingContinueWatchingDismissals.remove(target)) {
                latestAuthoritativeRows?.let { rows ->
                    baseRows = continueWatchingRollbacks.remove(target)
                        ?.let { restoreContinueWatchingItem(rows, it) }
                        ?: rows
                }
                publishHome()
            }
        }
    }

    fun loadNextPage(catalog: Catalog) {
        scope.launch { repo.loadHomeRowNextPage(catalog) }
    }

    fun loadMoreRows() {
        scope.launch { repo.loadMoreHomeRows() }
    }

    private companion object {
        const val EMPTY_TIMEOUT_MS = 15_000L
        const val CONFIRMATION_TIMEOUT_MS = 3_000L
        const val CONFIRMATION_POLL_MS = 75L
    }
}

private data class ContinueWatchingRollback(
    val row: Catalog,
    val rowIndex: Int,
    val item: MetaItem,
    val itemIndex: Int,
)

private fun captureContinueWatchingRollback(
    rows: List<Catalog>,
    target: ContinueWatchingDismissal,
): ContinueWatchingRollback? {
    val rowIndex = rows.indexOfFirst { it.id == "continue" }
    val row = rows.getOrNull(rowIndex) ?: return null
    val itemIndex = row.items.indexOfFirst { it.type == target.type && it.id == target.id }
    val item = row.items.getOrNull(itemIndex) ?: return null
    return ContinueWatchingRollback(row, rowIndex, item, itemIndex)
}

private fun restoreContinueWatchingItem(
    rows: List<Catalog>,
    rollback: ContinueWatchingRollback,
): List<Catalog> {
    val existingRowIndex = rows.indexOfFirst { it.id == rollback.row.id }
    if (existingRowIndex < 0) {
        val insertionIndex = rollback.rowIndex.coerceIn(0, rows.size)
        return rows.toMutableList().apply {
            add(insertionIndex, rollback.row.copy(items = listOf(rollback.item)))
        }
    }
    val existingRow = rows[existingRowIndex]
    if (existingRow.items.any { it.type == rollback.item.type && it.id == rollback.item.id }) return rows
    val restoredItems = existingRow.items.toMutableList().apply {
        add(rollback.itemIndex.coerceIn(0, size), rollback.item)
    }
    return rows.toMutableList().apply {
        this[existingRowIndex] = existingRow.copy(items = restoredItems)
    }
}

internal fun withoutContinueWatchingItems(
    rows: List<Catalog>,
    pending: Set<ContinueWatchingDismissal>,
    owner: ContinueWatchingOwner,
): List<Catalog> {
    val removed = pending.filterTo(hashSetOf()) { it.owner == owner }
    if (removed.isEmpty()) return rows
    return rows.mapNotNull { row ->
        if (row.id != "continue") return@mapNotNull row
        row.copy(
            items = row.items.filterNot { item ->
                ContinueWatchingDismissal(owner, item.type, item.id) in removed
            },
        ).takeIf { it.items.isNotEmpty() }
    }
}

internal suspend fun awaitContinueWatchingAbsent(
    target: ContinueWatchingDismissal,
    snapshot: suspend () -> Result<ContinueWatchingSnapshot>,
    timeoutMs: Long = 3_000L,
    pollMs: Long = 75L,
): Boolean = withTimeoutOrNull(timeoutMs) {
    var confirmed = false
    while (!confirmed) {
        val authoritative = snapshot().getOrNull() ?: break
        if (authoritative.owner != target.owner) break
        if (authoritative.items.none { it.id == target.id && it.type == target.type }) {
            confirmed = true
            break
        }
        delay(pollMs)
    }
    confirmed
} ?: false

/// Discover: the engine-driven type/catalog/genre pivot (S04). REPLACES the old static-[MediaType]
/// chip switch: that switch dispatched the SAME `args: null` Load regardless of which chip was tapped
/// (see [com.vortx.android.engine.EngineActions.loadDiscover]'s old doc), so every type/catalog
/// selection rendered the exact same rail -- the "Discover chips are inert" bug this session fixes.
/// Every selection now re-dispatches the chip's own `request` JSON verbatim (never reconstructed), and
/// filters + items come back from a SINGLE engine round-trip (see
/// [com.vortx.android.engine.EngineStremioRepository.discoverResultFrom]).
class DiscoverViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<DiscoverResult>>(UiState.Loading)
    val state: StateFlow<UiState<DiscoverResult>> = _state.asStateFlow()

    private val _loadingMore = MutableStateFlow(false)
    val loadingMore: StateFlow<Boolean> = _loadingMore.asStateFlow()

    private var currentRequestJson: String? = null
    private var everLoaded = false
    private var selectJob: Job? = null

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): re-drives the CURRENT selection
    /// whenever an add-on is installed/removed or the signed-in identity changes, so Discover's
    /// catalogs/chips pick up the new add-on set live instead of needing a stray chip tap or a restart
    /// (device finding 1c). Runs for the ViewModel's whole lifetime, independent of [select]/[selectJob]
    /// (a manual pivot cancels/replaces the in-flight load same as before; this just ALSO fires that
    /// same load path on an external change). The FIRST tick (fired immediately on collection, see
    /// [CatalogRepository.ctxUpdates]) is the screen's normal entry-point load, replacing the old
    /// `init { select(null) }`.
    init {
        viewModelScope.launch {
            repo.ctxUpdates().collect { reconcileSelection() }
        }
    }

    /// The ctx-change re-drive (see [init]'s doc). Device finding: with the "TV" type chip selected
    /// showing one add-on's channels, removing that add-on left both the stale channels AND the dead
    /// type/catalog chip on screen until the user tapped another chip or restarted. A straight
    /// `select(currentRequestJson, ...)` re-dispatch can't fix this -- [currentRequestJson] is the
    /// engine's own verbatim `request` for the now-uninstalled add-on's catalog, and re-selecting the
    /// EXACT SAME request the engine already has selected does not force it to recompute `selectable`
    /// against the current add-on set, so both the stale grid and the stale chip stick around.
    ///
    /// Instead: always ask for the engine's own DEFAULT selection first ([requestJson] = null), which
    /// always recomputes `selectable` fresh from whatever add-ons are CURRENTLY installed (mirrors a
    /// first-time entry into Discover, and the engine/Apple's own fallback). If the user's prior pick
    /// is still offered among that fresh `selectable` (the common case -- an unrelated add-on
    /// installed/removed, or nothing to do with the current selection), immediately re-select it so
    /// their place in Discover isn't reset just because *something* changed -- this is what keeps
    /// "installing an add-on adds its chips/catalogs live" working. If it is NOT offered anymore (its
    /// add-on was the one removed), the fresh default result IS the reconciled state: the dead
    /// channels and the dead chip are both gone, with no chip tap or restart needed.
    private fun reconcileSelection() {
        val requestJson = currentRequestJson
        selectJob?.cancel()
        val showLoading = !everLoaded
        if (showLoading) _state.value = UiState.Loading
        selectJob = viewModelScope.launch {
            val fresh = repo.discover(null)
            val stillOffered = requestJson != null && fresh.getOrNull()?.filters?.let { f ->
                f.types.any { it.requestJson == requestJson } ||
                    f.catalogs.any { it.requestJson == requestJson } ||
                    f.genres.any { it.requestJson == requestJson }
            } == true
            val result = if (stillOffered) repo.discover(requestJson) else fresh
            currentRequestJson = if (stillOffered) requestJson else null
            _state.value = result.toUiState()
            everLoaded = true
        }
    }

    /// Pivot to a specific type/catalog/genre. [requestJson] is null for the engine's own default
    /// (first load, and the entry point for the whole screen), or a chip's `requestJson` from the
    /// current [DiscoverResult.filters]. [showLoading] is false for a background re-drive (an add-on
    /// change while the user is already browsing a selection) so the grid doesn't flash back to the
    /// shimmer underneath them.
    fun select(requestJson: String?, showLoading: Boolean = true) {
        currentRequestJson = requestJson
        selectJob?.cancel()
        if (showLoading) _state.value = UiState.Loading
        selectJob = viewModelScope.launch {
            _state.value = repo.discover(requestJson).toUiState()
            everLoaded = true
        }
    }

    fun retry() = select(null)

    /// "Load more" (DESIGN-SYSTEM.md §4 "Discover / Search": "'Load more' (per-catalog skip)"). The
    /// engine APPENDS the next page to the already-loaded catalog, so the returned items already
    /// contain everything loaded so far -- no manual merge needed here.
    ///
    /// GROUP 2a (device-verified crash): root-caused to a duplicate poster id across a page boundary
    /// hitting `LazyVerticalGrid`'s `key = { it.id }` in [com.vortx.android.ui.screens.PosterGrid] --
    /// fixed at the source in [com.vortx.android.engine.EngineState.parseCatalogWithFilters] (dedupe
    /// while flattening pages) plus a defense-in-depth dedupe in the grid itself. `runCatching` + a
    /// logged failure here is additional hardening so a genuinely NEW crash mode surfaces as a caught,
    /// logged error (visible via `adb logcat -s StremioXDiscover`) instead of taking the app down again,
    /// and captures the next device round's logcat if this was not the only failure mode.
    fun loadMore() {
        val filters = (_state.value as? UiState.Success)?.data?.filters ?: return
        if (!filters.hasNextPage || _loadingMore.value) return
        viewModelScope.launch {
            _loadingMore.value = true
            runCatching { repo.discoverNextPage() }
                .onSuccess { result -> result.onSuccess { _state.value = UiState.Success(it) } }
                .onFailure { Log.e(TAG, "loadMore: discoverNextPage threw", it) }
            _loadingMore.value = false
        }
    }

    private companion object {
        const val TAG = "StremioXDiscover"
    }
}

/// Library: the engine-driven type/sort pivot + add/remove (S04). Re-loads on every filter switch and
/// after a library mutation, keeping the currently applied [requestJson] so a remove doesn't silently
/// reset the user's filter/sort choice.
class LibraryViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<LibraryResult>>(UiState.Loading)
    val state: StateFlow<UiState<LibraryResult>> = _state.asStateFlow()

    private var currentRequestJson: String? = null
    private var everLoaded = false
    private var loadJob: Job? = null

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): Library is DERIVED state
    /// (`ctx.library`), so an Add-to-Library from Detail/a poster, or a Remove from this screen's OWN
    /// trash badge, must re-render this grid the instant either happens -- not only on the next screen
    /// visit or a stray filter-chip tap (device finding 1a). Collected for the ViewModel's whole
    /// lifetime; the FIRST tick (fired immediately, see [CatalogRepository.ctxUpdates]) is the screen's
    /// normal entry-point load, replacing the old `init { load(null) }`.
    init {
        viewModelScope.launch {
            repo.ctxUpdates().collect { load(currentRequestJson, showLoading = !everLoaded) }
        }
    }

    fun load(requestJson: String?, showLoading: Boolean = true) {
        currentRequestJson = requestJson
        loadJob?.cancel()
        if (showLoading) _state.value = UiState.Loading
        loadJob = viewModelScope.launch {
            _state.value = repo.library(requestJson).toUiState()
            everLoaded = true
        }
    }

    fun retry() = load(currentRequestJson)

    /// Remove a title from the Library (the grid's per-poster "x" control). [repo.removeFromLibrary] is
    /// itself a ctx broadcast, so [ctxUpdates] also re-loads independently -- this explicit reload just
    /// keeps the removal feeling instant rather than waiting on the next event tick.
    fun remove(id: String) {
        viewModelScope.launch {
            repo.removeFromLibrary(id)
            _state.value = repo.library(currentRequestJson).toUiState()
        }
    }
}

/// Search: debounced full-text query across every installed add-on. An empty query is a calm idle
/// state, never an error. [history] surfaces recent searches (DESIGN-SYSTEM.md §4 "Discover / Search":
/// "Recent searches as chips when empty"), ported from Apple `SearchHistoryStore` -- see
/// [SearchHistoryStore]'s doc for the plain-prefs rationale.
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class SearchViewModel(private val repo: CatalogRepository, private val historyStore: SearchHistoryStore) : ViewModel() {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val _history = MutableStateFlow(historyStore.load())
    val history: StateFlow<List<String>> = _history.asStateFlow()

    val state: StateFlow<UiState<List<MetaItem>>> = _query
        .debounce { if (it.isBlank()) 0L else SEARCH_DEBOUNCE_MS }
        .distinctUntilChanged()
        .flatMapLatest { q ->
            flow {
                if (q.isNotBlank()) emit(UiState.Loading)
                emit(repo.search(q).toUiState())
            }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Success(emptyList()))

    fun onQueryChange(value: String) {
        _query.value = value
    }

    /// Record the CURRENT query in history (mirrors Apple: recorded when a result is actually opened,
    /// not on every keystroke) and refresh the published list. Called by the screen's `onItem`.
    fun recordHistory() {
        val q = _query.value
        historyStore.add(q)
        _history.value = historyStore.load()
    }

    fun clearHistory() {
        historyStore.clear()
        _history.value = emptyList()
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 350L
    }
}
