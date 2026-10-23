package com.vortx.android.stats

import com.vortx.android.data.CatalogRepository
import com.vortx.android.engine.NativeCatalogRepository
import com.vortx.android.engine.NativeWatchStatsSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

/** The UI state one Watch Stats screen renders. Immutable; the screen only formats it. */
data class WatchStatsUiState(
    /**
     * True while the first load reads + parses the buckets off the main thread. Starts true so the very
     * first frame (before [WatchStatsModel.load]) shows the loader, not a false "no history" state.
     */
    val isLoading: Boolean = true,
    /** The computed stats for the selected scope (null until the first load completes). */
    val stats: WatchStats? = null,
    /** Years present in the watch history, newest first, for the "year in review" scope picker. */
    val availableYears: List<Int> = emptyList(),
    /** null = all time; otherwise a specific calendar year. */
    val selectedYear: Int? = null,
    val error: String? = null,
)

/**
 * Personal watch statistics ("year in review"), computed READ ONLY from the ACTIVE profile's existing
 * watch signal. The Android port of Apple `app/SourcesShared/WatchStatsModel.swift`. This never
 * dispatches an engine action, never writes an engine / profile / library document, and never mutates
 * watched state: it only READS what is already persisted. The deterministic aggregation lives in the
 * pure [WatchStats]; this type owns only the engine-coupled orchestration.
 *
 * The engine's native repository produces the active profile's watch records and genre index as one
 * snapshot ([NativeCatalogRepository.watchStatsSnapshot]); a scope change recomputes in memory under that
 * same snapshot. An unavailable session reports an explicit error instead of borrowing another history.
 */
class WatchStatsModel(private val repository: CatalogRepository? = null) {

    private val _state = MutableStateFlow(WatchStatsUiState())
    val state = _state.asStateFlow()

    /** The normalized records for the active profile, cached so a scope change is an in-memory recompute. */
    private var records: List<WatchRecord> = emptyList()

    /** metaId -> genres, joined from the engine's in-memory catalog / detail state. */
    private var genresByID: Map<String, List<String>> = emptyMap()
    private var nativeSnapshot: NativeWatchStatsSnapshot? = null

    /**
     * Read the active profile's watch history (read only) and compute stats. Safe to call repeatedly; it
     * fully rebuilds. The heavy bucket read + JSON parse run off the main thread; the scope years and the
     * first compute are derived on return.
     */
    suspend fun load() = withContext(Dispatchers.IO) {
        _state.update { it.copy(isLoading = true) }
        try {
            val native = checkNotNull(repository as? NativeCatalogRepository) { "Native stats repository unavailable" }
            val snapshot = native.watchStatsSnapshot()
            native.withWatchStatsSnapshot(snapshot) {
                nativeSnapshot = snapshot; records = snapshot.records; genresByID = snapshot.genres
                _state.update { it.copy(error = null) }; finishLoad()
            }
        } catch (_: Exception) { nativeUnavailable() }
    }

    /** Switch the scope. Pure + in-memory (never re-reads the buckets), so it is cheap to call on the main thread. */
    fun selectYear(year: Int?) {
        try {
            val native = checkNotNull(repository as? NativeCatalogRepository)
            native.withWatchStatsSnapshot(checkNotNull(nativeSnapshot)) {
                _state.update { it.copy(selectedYear = year) }; recompute()
            }
        } catch (_: Exception) { nativeUnavailable() }
    }

    private fun nativeUnavailable() {
        records = emptyList(); genresByID = emptyMap(); nativeSnapshot = null
        _state.value = WatchStatsUiState(isLoading = false, error = "Native watch history is unavailable for the current account.")
    }

    /** Derive the scope years and compute the selected scope. */
    private fun finishLoad() {
        val years = records.mapNotNull { r -> r.lastWatched?.let { WatchStats.yearOf(it) } }
            .distinct()
            .sortedDescending()
        val current = _state.value.selectedYear
        // Drop a stale selection that no longer exists in this profile's data.
        val selected = if (current != null && !years.contains(current)) null else current
        _state.update { it.copy(isLoading = false, availableYears = years, selectedYear = selected) }
        recompute()
    }

    /** Filter the cached records to the selected scope and compute. Pure + in-memory. */
    private fun recompute() {
        val year = _state.value.selectedYear
        val scoped = if (year == null) {
            records
        } else {
            records.filter { r -> r.lastWatched?.let { WatchStats.yearOf(it) == year } ?: false }
        }
        val label = year?.toString() ?: "All time"
        val stats = WatchStats.compute(
            records = scoped,
            genresByID = genresByID,
            scopeLabel = label,
            topTitles = WatchStats.TOP_TITLES_LIMIT,
            topGenres = WatchStats.TOP_GENRES_LIMIT,
        )
        _state.update { it.copy(stats = stats) }
    }
}
