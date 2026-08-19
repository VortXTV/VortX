package com.vortx.android.iptv

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.Catalog
import com.vortx.android.model.LiveTypes
import com.vortx.android.ui.UiState
import com.vortx.android.ui.viewmodel.HomeUpdateReducer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

/// Live TV: the Android twin of Apple's `iOSLiveView` / tvOS `LiveView`. It renders the engine board's
/// live-TV / channel / events catalogs (the ones an installed IPTV / live add-on exposes -- including
/// the ones the hosted `iptv.vortx.tv` converter installs from a user's M3U or Xtream login) as a
/// dedicated surface, distinct from the VOD Home. Like Apple, it REUSES the engine + player wholesale:
/// there is no local M3U parse and no in-app EPG, the channels flow through the same catalog pipeline the
/// rest of the app renders, and tapping one opens the shared detail page whose live branch plays the
/// stream through the existing player. This ViewModel only re-projects the board.
///
/// It collects the SAME continuous [CatalogRepository.homeUpdates] stream Home does (so a live add-on
/// installed mid-session makes its channels appear here live, and a sign-in/out swaps the set), then
/// keeps ONLY the rows whose catalog [Catalog.type] is a live type ([LiveTypes]). It also asks the
/// repository to widen the board to every catalog ([CatalogRepository.ensureLiveCatalogsLoaded]),
/// because live catalogs are usually ordered after an add-on's movie/series catalogs and so fall outside
/// the default board window -- the Android analogue of Apple `CoreBridge.ensureLiveCatalogsLoaded`,
/// called on entry and whenever the installed add-on set changes.
class LiveViewModel internal constructor(
    private val repo: CatalogRepository,
    private val scopeOverride: CoroutineScope? = null,
) : ViewModel() {

    private val _state = MutableStateFlow<UiState<List<Catalog>>>(UiState.Loading)
    val state: StateFlow<UiState<List<Catalog>>> = _state.asStateFlow()

    private val scope: CoroutineScope get() = scopeOverride ?: viewModelScope
    private var collectJob: Job? = null

    init {
        load()
        // Re-widen the board whenever the installed add-on set (or sign-in identity) changes, mirroring
        // Apple LiveView's `onChange(of: core.addons.count) { core.ensureLiveCatalogsLoaded() }`: an
        // add-on that provides live catalogs must make its channels appear here without a manual reload.
        scope.launch {
            // ensureLiveCatalogsLoaded() already returns Result and catches its own dispatch failures, so
            // no outer runCatching is needed here -- wrapping it would only swallow a real
            // CancellationException and break structured cancellation of this collector.
            repo.ctxUpdates().collect { repo.ensureLiveCatalogsLoaded() }
        }
    }

    fun load() {
        collectJob?.cancel()
        _state.value = UiState.Loading
        collectJob = scope.launch {
            val reducer = HomeUpdateReducer()
            // Watchdog: an engine that never settles a board (no network AND no cache) must fall to the
            // composed empty nudge rather than shimmering forever, matching Home's own watchdog.
            launch {
                delay(EMPTY_TIMEOUT_MS)
                if (_state.value is UiState.Loading) _state.value = UiState.Success(emptyList())
            }
            repo.homeUpdates()
                .catch { error ->
                    _state.value = UiState.Error(error.message ?: "Couldn't load Live TV. Check your connection and try again.")
                }
                .collect { update ->
                    // Widen toward the full board on every tick; it no-ops once fully loaded. The return
                    // value tells us when the board has finished loading, so an empty live set is only
                    // shown as "no Live TV add-ons" once the whole board has settled -- never mid-load. Use
                    // the method's own Result (it catches its own dispatch failures) and let a real
                    // CancellationException propagate rather than swallowing it in an outer runCatching.
                    val boardFullyLoaded = repo.ensureLiveCatalogsLoaded().getOrDefault(true)
                    // A non-null reduction is a real board snapshot (a non-empty board, or an authoritative
                    // sign-out clear), so reaching here means the board has content to classify.
                    val reduced = reducer.reduce(update) ?: return@collect
                    val liveRows = (reduced as UiState.Success).data.filter(::isLiveRow)
                    when {
                        liveRows.isNotEmpty() -> _state.value = UiState.Success(liveRows)
                        // Empty live set is a real, settled answer only once the WHOLE board has loaded
                        // (every catalog range-loaded); until then it is just "the live catalogs, ordered
                        // last, have not hydrated yet", so hold Loading rather than flashing the nudge.
                        boardFullyLoaded -> _state.value = UiState.Success(emptyList())
                        else -> Unit
                    }
                }
        }
    }

    fun retry() = load()

    /// A board row is Live TV when its declared catalog [Catalog.type] is a live type (tv / channel /
    /// events / ...). Continue Watching and the client-side personalized rails carry no engine type and
    /// so are never live. Mirrors Apple `CoreBridge.liveBoardRows` (`boardRows.filter { LiveTypes.contains($0.type) }`).
    private fun isLiveRow(catalog: Catalog): Boolean =
        catalog.type?.let(LiveTypes::contains) == true

    private companion object {
        const val EMPTY_TIMEOUT_MS = 15_000L
    }
}
