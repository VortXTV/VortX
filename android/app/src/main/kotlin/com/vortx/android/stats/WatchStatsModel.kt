package com.vortx.android.stats

import com.vortx.android.engine.EngineActions
import com.vortx.android.engine.EngineState
import com.vortx.android.engine.StremioCoreNative
import com.vortx.android.model.AuthState
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.WatchEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.max

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
)

/**
 * Personal watch statistics ("year in review"), computed READ ONLY from the ACTIVE profile's existing
 * watch signal. The Android port of Apple `app/SourcesShared/WatchStatsModel.swift`. This never
 * dispatches an engine action, never writes an engine / profile / library document, and never mutates
 * watched state: it only READS what is already persisted. The deterministic aggregation lives in the
 * pure [WatchStats]; this type owns only the engine-coupled orchestration.
 *
 * PER-PROFILE HISTORY BOUNDARY (the repository invariant, mirroring Apple's `activeUsesEngineHistory`
 * split and the Android [com.vortx.android.library.WatchedIndex]):
 *  - OWNER / own-account profile ([ProfileStore.activeUsesEngineHistory] == true): the engine's OWN
 *    current-account history. Precise watch time comes from the engine's persisted library buckets
 *    (`library.json` / `library_recent.json` in the app's `filesDir`), each carrying a title's
 *    `state.overallTimeWatched` (ms), `timesWatched`, and `lastWatched`. A bucket is consumed only when
 *    its `uid` matches the live account uid -- OR when signed OUT (no uid), where the on-disk history is
 *    the user's own with no other account to leak from. On TOP of the buckets, the engine's LIVE library
 *    and Continue-Watching models are unioned in so the screen never goes empty when a bucket was skipped
 *    by the uid gate or not yet written to disk.
 *  - OVERLAY profile (== false): ONLY that profile's private overlay ([ProfileStore.watch]), NEVER the
 *    account/engine set. Watch time is estimated from the overlay's per-title `durationMs` + watched
 *    episode list.
 *
 * Genres are not stored in the library, so the genre breakdown is a best-effort join against whatever
 * catalog / detail state the engine currently holds. Everything is fail-soft: a missing / unreadable
 * bucket contributes nothing rather than crashing.
 */
class WatchStatsModel(private val storageDir: File) {

    private val _state = MutableStateFlow(WatchStatsUiState())
    val state = _state.asStateFlow()

    /** The normalized records for the active profile, cached so a scope change is an in-memory recompute. */
    private var records: List<WatchRecord> = emptyList()

    /** metaId -> genres, joined from the engine's in-memory catalog / detail state. */
    private var genresByID: Map<String, List<String>> = emptyMap()

    /**
     * Read the active profile's watch history (read only) and compute stats. Safe to call repeatedly; it
     * fully rebuilds. The heavy bucket read + JSON parse run off the main thread; the scope years and the
     * first compute are derived on return.
     */
    suspend fun load() = withContext(Dispatchers.IO) {
        _state.update { it.copy(isLoading = true) }
        val genres = buildGenreIndex()
        val store = ProfileStore.sharedOrNull()
        // Default to the engine path when the store is not up yet (pre-init), mirroring Apple's
        // `activeUsesEngineHistory` default of true.
        val usesEngine = store?.activeUsesEngineHistory ?: true
        val recs = if (usesEngine) ownerRecords() else overlayRecords(store?.watch ?: emptyMap())
        genresByID = genres
        records = recs
        finishLoad()
    }

    /** Switch the scope. Pure + in-memory (never re-reads the buckets), so it is cheap to call on the main thread. */
    fun selectYear(year: Int?) {
        if (year == _state.value.selectedYear) return
        _state.update { it.copy(selectedYear = year) }
        recompute()
    }

    /** Common tail of both load paths: derive the scope years and compute the selected scope. */
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

    // ---- Owner path (engine buckets + live merge, read only) ----

    private fun ownerRecords(): List<WatchRecord> {
        val expectedUid =
            (EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField())) as? AuthState.SignedIn)?.uid
        val bucket = bucketRecords(expectedUid)
        val liveLibrary = StremioCoreNative.getState(EngineActions.libraryField())
        val liveCw = StremioCoreNative.getState(EngineActions.continueWatchingPreviewField())
        return mergeLive(bucket, liveLibrary, liveCw)
    }

    /**
     * Full watch records from BOTH persisted engine buckets, gated on [expectedUid] exactly like
     * [com.vortx.android.library.WatchedIndex]. `library.json` (the whole library) is read first, then
     * `library_recent.json` (the fresher subset) overwrites shared ids. Fail-soft. READ ONLY.
     *
     * UID GATE: a file whose `uid` does not match [expectedUid] is skipped so a PREVIOUS account's bucket
     * can never leak into a DIFFERENT signed-in account's numbers. The one relaxation, mirroring Apple's
     * `WatchStatsModel.bucketRecords`: when signed OUT ([expectedUid] == null) the on-disk bucket is the
     * user's OWN last-synced history with no other account to leak from, so it is accepted.
     */
    private fun bucketRecords(expectedUid: String?): MutableMap<String, WatchRecord> {
        val out = LinkedHashMap<String, WatchRecord>()
        for (name in BUCKET_NAMES) {
            val file = File(storageDir, name)
            if (!file.isFile) continue
            val root = runCatching { JSONObject(file.readText()) }.getOrNull() ?: continue
            val items = root.optJSONObject("items") ?: continue
            val bucketUid = if (root.has("uid") && !root.isNull("uid")) root.optString("uid") else null
            if (!(bucketUid == expectedUid || expectedUid == null)) continue
            val keys = items.keys()
            while (keys.hasNext()) {
                val id = keys.next()
                val item = items.optJSONObject(id) ?: continue
                val record = recordFromBucketItem(id, item) ?: continue
                out[id] = record
            }
        }
        return out
    }

    /**
     * Normalize one persisted `LibraryItem` JSON into a [WatchRecord], or null to skip it (internal docs,
     * non-VOD types, nothing watched). Mirrors Apple `WatchStats.record(fromBucketItem:)`.
     */
    private fun recordFromBucketItem(id: String, item: JSONObject): WatchRecord? {
        val type = item.optString("type", "")
        if (!WatchStats.isVODType(type) || WatchStats.isInternalID(id)) return null
        val stateObj = item.optJSONObject("state") ?: JSONObject()
        val overallMs = stateObj.optDouble("overallTimeWatched", 0.0)
        val timesWatched = stateObj.optInt("timesWatched", 0)
        val flaggedWatched = stateObj.optInt("flaggedWatched", 0)
        // Keep only titles the user has actually engaged with: real watch time, a finished play / watched
        // episode, or a watched-from-catalog mark. A bare library add (never played) contributes nothing.
        if (!(overallMs > 0.0 || timesWatched > 0 || flaggedWatched > 0)) return null
        val name = item.optString("name", "").ifEmpty { id }
        val poster = stringOrNull(item, "poster")
        val last = WatchStats.parseISODate(stringOrNull(stateObj, "lastWatched"))
        return WatchRecord(
            id = id,
            type = type,
            name = name,
            poster = poster,
            watchSeconds = WatchStats.clampSeconds(overallMs / 1000.0),
            plays = WatchStats.clampPlayCount(timesWatched),
            lastWatched = last,
        )
    }

    /**
     * Union in any live library / Continue-Watching title MISSING from the persisted buckets: the
     * fresh-mark catch-up AND the whole-history fallback when the buckets were skipped by the uid gate or
     * never written on this device. Watch time is estimated from the live state (the published CW item
     * carries no `overallTimeWatched`). Mirrors Apple `WatchStatsModel.mergeLive`. READ ONLY.
     */
    private fun mergeLive(
        bucket: MutableMap<String, WatchRecord>,
        libraryJson: String,
        continueWatchingJson: String,
    ): List<WatchRecord> {
        val live = jsonObjects(libraryJson, "catalog") + jsonObjects(continueWatchingJson, "items")
        for (obj in live) {
            val id = obj.optString("_id").ifEmpty { obj.optString("id") }
            if (id.isEmpty() || bucket.containsKey(id)) continue
            val type = obj.optString("type", "")
            if (!WatchStats.isVODType(type) || WatchStats.isInternalID(id)) continue
            val stateObj = obj.optJSONObject("state") ?: JSONObject()
            val timesWatched = stateObj.optInt("timesWatched", 0)
            val timeOffset = stateObj.optDouble("timeOffset", 0.0)
            val duration = stateObj.optDouble("duration", 0.0)
            val isWatched = timesWatched > 0
            if (!(isWatched || timeOffset > 0.0)) continue
            val isSeries = type == "series"
            val durationS = duration / 1000.0
            val seconds = when {
                isSeries -> durationS * max(timesWatched, 1)                 // episodes * per-episode duration
                isWatched -> durationS                                        // finished movie
                else -> timeOffset / 1000.0                                   // in-progress movie
            }
            bucket[id] = WatchRecord(
                id = id,
                type = type,
                name = obj.optString("name", ""),
                poster = stringOrNull(obj, "poster"),
                watchSeconds = WatchStats.clampSeconds(seconds),
                plays = WatchStats.clampPlayCount(timesWatched),
                lastWatched = null,
            )
        }
        return bucket.values.toList()
    }

    // ---- Overlay path (private overlay, read only) ----

    /**
     * Records from an overlay profile's private watch overlay. Watch time is estimated: the overlay stores
     * a per-title `durationMs` (the last-played video's duration) and the set of watched episode ids, so a
     * series is `watchedEpisodes * durationMs` and a movie is its full duration when finished or its resume
     * offset while in progress. Mirrors Apple `WatchStatsModel.overlayRecords`. READ ONLY (never writes).
     */
    private fun overlayRecords(watch: Map<String, WatchEntry>): List<WatchRecord> {
        val out = ArrayList<WatchRecord>()
        for ((metaId, entry) in watch) {
            if (!WatchStats.isVODType(entry.type) || WatchStats.isInternalID(metaId)) continue
            val isSeries = entry.type == "series"
            val durationS = entry.durationMs / 1000.0
            val episodes = entry.watchedVideoIds.size
            val seconds: Double
            val plays: Int
            if (isSeries) {
                seconds = durationS * episodes
                plays = episodes
            } else {
                val finished = entry.progress >= 0.9 || entry.watchedVideoIds.contains(entry.videoId ?: metaId)
                seconds = if (finished) durationS else entry.timeOffsetMs / 1000.0
                plays = if (finished || seconds > 0.0) 1 else 0
            }
            if (!(seconds > 0.0 || plays > 0)) continue
            out += WatchRecord(
                id = metaId,
                type = entry.type,
                name = entry.name,
                poster = entry.poster,
                watchSeconds = WatchStats.clampSeconds(seconds),
                plays = plays,
                lastWatched = WatchStats.parseISODate(entry.lastWatched),
            )
        }
        return out
    }

    // ---- Genre index (best-effort, current engine catalog / detail state only) ----

    /**
     * Join whatever catalog / detail state the engine currently holds into a metaId -> genres lookup. This
     * is the only local source of genres (the library stores none), so coverage is partial by design: it
     * reflects titles whose catalog card or detail the user has loaded. Read-only; never fetches. Mirrors
     * the intent of Apple `WatchStatsModel.buildGenreIndex` (which reads CoreBridge's published catalogs).
     */
    private fun buildGenreIndex(): Map<String, List<String>> {
        val index = LinkedHashMap<String, List<String>>()
        fun add(id: String?, genres: List<String>) {
            if (id.isNullOrEmpty() || genres.isEmpty() || index.containsKey(id)) return
            index[id] = genres
        }
        runCatching {
            for (catalog in EngineState.parseCatalogs(StremioCoreNative.getState(EngineActions.boardField()))) {
                for (meta in catalog.items) add(meta.id, meta.genres)
            }
        }
        runCatching {
            for (catalog in EngineState.parseCatalogWithFilters(StremioCoreNative.getState(EngineActions.discoverField()))) {
                for (meta in catalog.items) add(meta.id, meta.genres)
            }
        }
        runCatching {
            val (items, _) = EngineState.parseSearchUpdate(
                StremioCoreNative.getState(searchField()),
                Int.MAX_VALUE,
            )
            for (meta in items) add(meta.id, meta.genres)
        }
        runCatching {
            EngineState.parseMetaDetail(StremioCoreNative.getState(EngineActions.metaDetailsField()))
                ?.let { add(it.id, it.genres) }
        }
        return index
    }

    // ---- JSON helpers ----

    /** The objects of the JSON array at [key] in [json] (`{ <key>: [ {...} ] }`), fail-soft to empty. */
    private fun jsonObjects(json: String, key: String): List<JSONObject> {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return emptyList()
        val array: JSONArray = root.optJSONArray(key) ?: return emptyList()
        val out = ArrayList<JSONObject>(array.length())
        for (i in 0 until array.length()) array.optJSONObject(i)?.let { out += it }
        return out
    }

    /** Like `optString` but null (not "") for a missing / JSON-null / blank value, so optionals stay absent. */
    private fun stringOrNull(obj: JSONObject, key: String): String? {
        if (!obj.has(key) || obj.isNull(key)) return null
        return obj.optString(key).ifBlank { null }
    }

    private fun searchField(): String = "\"${EngineActions.FIELD_SEARCH}\""

    private companion object {
        private val BUCKET_NAMES = listOf("library.json", "library_recent.json")
    }
}
