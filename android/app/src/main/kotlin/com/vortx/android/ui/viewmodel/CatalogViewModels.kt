package com.vortx.android.ui.viewmodel

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.home.BecauseYouWatchedModel
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
import com.vortx.android.model.Catalog
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.search.SearchHistoryStore
import com.vortx.android.ui.UiState
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

/// Maps a repository [Result] to a [UiState], turning a thrown/failed add-on call into a visible
/// error instead of an empty screen. Shared by every catalog ViewModel.
private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)

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
) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<Catalog>>>(UiState.Loading)
    val state: StateFlow<UiState<List<Catalog>>> = _state.asStateFlow()

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
    private var releaseOwnerGeneration = 0L
    private var releaseOwner = ReleaseCalendarOwner(activeProfileId(), releaseOwnerGeneration)

    init {
        load()
        viewModelScope.launch {
            repo.ctxUpdates().drop(1).collectLatest {
                advanceReleaseOwner()
                watchlistStore?.reload()
                refreshPersonalizedRails()
            }
        }
        watchlistStore?.let { store ->
            viewModelScope.launch {
                store.items.drop(1).collectLatest { refreshPersonalizedRails() }
            }
        }
        viewModelScope.launch {
            TraktAuth.sessionBoundary.drop(1).collectLatest {
                traktRails.clear()
                traktWatchlist = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        viewModelScope.launch {
            SIMKLAuth.sessionBoundary.drop(1).collectLatest {
                simklRails.clear()
                simklWatchlist = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        viewModelScope.launch {
            MediaServerRepository.configurationBoundary.drop(1).collectLatest {
                mediaServerCatalogs.clear()
                mediaServerRails = emptyList()
                publishHome()
                refreshPersonalizedRails()
            }
        }
        importedCatalogs?.let { registry ->
            viewModelScope.launch {
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
        _state.value = UiState.Loading
        collectJob = viewModelScope.launch {
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
                repo.homeUpdates().combine(preferences.state) { rows, _ ->
                    rows.isNotEmpty() to rows
                }
            } ?: repo.homeUpdates().map { rows -> rows.isNotEmpty() to rows }
            homeUpdates
                .catch { error ->
                    _state.value = UiState.Error(error.message ?: "Something went wrong loading your add-ons.")
                }
                .collect { (sourceHasRows, rows) ->
                    // Empty emissions are the stream's "nothing settled yet" heartbeat -- keep the
                    // shimmer (or the previous Success) rather than rendering an empty Home. A non-empty
                    // source that becomes empty only after the user's visibility filter is still a real
                    // settled result, so publish it instead of leaving the now-hidden rows on screen.
                    if (sourceHasRows) {
                        this@HomeViewModel.sourceHasRows = true
                        baseRows = rows
                        publishHome()
                        refreshPersonalizedRails()
                    }
                }
        }
        publishHome()
        refreshPersonalizedRails()
    }

    private fun refreshPersonalizedRails() {
        val owner = currentReleaseOwner()
        applyReleaseCalendar(releaseCalendar.activate(owner))
        val rows = baseRows
        personalizedJob?.cancel()
        personalizedJob = viewModelScope.launch {
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

    private fun currentReleaseOwner(): ReleaseCalendarOwner {
        val profileId = activeProfileId()
        if (profileId != releaseOwner.profileId) {
            releaseOwnerGeneration += 1
            releaseOwner = ReleaseCalendarOwner(profileId, releaseOwnerGeneration)
        }
        return releaseOwner
    }

    private fun advanceReleaseOwner() {
        releaseOwnerGeneration += 1
        releaseOwner = ReleaseCalendarOwner(activeProfileId(), releaseOwnerGeneration)
        if (applyReleaseCalendar(releaseCalendar.activate(releaseOwner))) publishHome()
    }

    private fun applyReleaseCalendar(refresh: ReleaseCalendarRefresh): Boolean {
        val changed = upcomingEpisodes != refresh.episodes || upcomingMovies != refresh.movies
        upcomingEpisodes = refresh.episodes
        upcomingMovies = refresh.movies
        return changed
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
        _state.value = UiState.Success(rows)
    }

    private companion object {
        const val EMPTY_TIMEOUT_MS = 15_000L
    }
}

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
