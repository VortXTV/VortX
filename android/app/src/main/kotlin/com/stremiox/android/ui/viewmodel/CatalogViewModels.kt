package com.stremiox.android.ui.viewmodel

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.DiscoverResult
import com.stremiox.android.model.LibraryResult
import com.stremiox.android.model.MetaItem
import com.stremiox.android.search.SearchHistoryStore
import com.stremiox.android.ui.UiState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
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
class HomeViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<Catalog>>>(UiState.Loading)
    val state: StateFlow<UiState<List<Catalog>>> = _state.asStateFlow()

    private var collectJob: Job? = null

    init {
        load()
    }

    fun load() {
        collectJob?.cancel()
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
            repo.homeUpdates()
                .catch { error ->
                    _state.value = UiState.Error(error.message ?: "Something went wrong loading your add-ons.")
                }
                .collect { rows ->
                    // Empty emissions are the stream's "nothing settled yet" heartbeat -- keep the
                    // shimmer (or the previous Success) rather than rendering an empty Home.
                    if (rows.isNotEmpty()) _state.value = UiState.Success(rows)
                }
        }
    }

    private companion object {
        const val EMPTY_TIMEOUT_MS = 15_000L
    }
}

/// Discover: the engine-driven type/catalog/genre pivot (S04). REPLACES the old static-[MediaType]
/// chip switch: that switch dispatched the SAME `args: null` Load regardless of which chip was tapped
/// (see [com.stremiox.android.engine.EngineActions.loadDiscover]'s old doc), so every type/catalog
/// selection rendered the exact same rail -- the "Discover chips are inert" bug this session fixes.
/// Every selection now re-dispatches the chip's own `request` JSON verbatim (never reconstructed), and
/// filters + items come back from a SINGLE engine round-trip (see
/// [com.stremiox.android.engine.EngineStremioRepository.discoverResultFrom]).
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
    /// hitting `LazyVerticalGrid`'s `key = { it.id }` in [com.stremiox.android.ui.screens.PosterGrid] --
    /// fixed at the source in [com.stremiox.android.engine.EngineState.parseCatalogWithFilters] (dedupe
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
