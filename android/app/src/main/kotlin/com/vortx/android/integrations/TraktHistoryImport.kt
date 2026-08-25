package com.vortx.android.integrations

import android.util.Log
import com.vortx.android.model.MediaRef
import org.json.JSONArray

/** WHY audit row 11: authenticated external watched-history import, with LWW delegated to the local store seam. */
internal object TraktHistoryImport {
    private const val TAG = "TraktHistoryImport"
    private const val PAGE_SIZE = 100
    private const val MAX_PAGES = 100

    data class WatchedItem(
        val ref: MediaRef,
        val watchedAt: String,
        val videoId: String,
    )

    /**
     * Wire this to the owner repository's setWatched/setVideoWatched path. localWatchedAt supplies the
     * engine/library clock, and apply must preserve [WatchedItem.watchedAt] when that store supports it.
     */
    data class Sink(
        val localWatchedAt: suspend (WatchedItem) -> String? = { null },
        val apply: suspend (WatchedItem) -> Boolean,
    )

    @Volatile private var sink: Sink? = null

    fun configure(value: Sink?) {
        sink = value
    }

    suspend fun run(): Int {
        if (!TraktAuth.isSignedIn ||
            !ScrobbleService.isToggleOn(ScrobbleService.KEY_TRAKT_IMPORT_WATCHED, false)
        ) return 0
        val target = sink
        if (target == null) {
            Log.d(TAG, "trakt history import: no owner watched-state sink wired")
            return 0
        }
        val deduped = LinkedHashMap<String, WatchedItem>()
        var fetched = 0
        for (kind in listOf("movies", "shows")) {
            for (page in 1..MAX_PAGES) {
                val response = TraktSyncSupport.request(
                    method = "GET",
                    path = "/sync/history/$kind?page=$page&limit=$PAGE_SIZE",
                )
                if (!response.isSuccess) break
                val array = runCatching { JSONArray(response.body) }.getOrNull() ?: break
                fetched += array.length()
                for (index in 0 until array.length()) {
                    val item = parse(array.optJSONObject(index), kind == "shows") ?: continue
                    val existing = deduped[item.videoId]
                    if (existing == null || existing.watchedAt < item.watchedAt) deduped[item.videoId] = item
                }
                if (array.length() < PAGE_SIZE) break
            }
        }
        var applied = 0
        for (item in deduped.values) {
            val local = runCatching { target.localWatchedAt(item) }.getOrNull()
            if (!local.isNullOrBlank() && local >= item.watchedAt) continue
            if (runCatching { target.apply(item) }.getOrDefault(false)) applied++
        }
        Log.d(TAG, "trakt history import: fetched=$fetched deduped=${deduped.size} applied=$applied")
        return applied
    }

    private fun parse(root: org.json.JSONObject?, series: Boolean): WatchedItem? {
        root ?: return null
        val watchedAt = root.optString("watched_at").takeIf { it.isNotBlank() } ?: return null
        val media = root.optJSONObject(if (series) "show" else "movie") ?: return null
        val ids = media.optJSONObject("ids") ?: return null
        val imdb = ids.optString("imdb").takeIf { it.startsWith("tt") }
        val tmdb = ids.optInt("tmdb", 0).takeIf { it > 0 }
        if (imdb == null && tmdb == null) return null
        val episode = root.optJSONObject("episode")
        val season = episode?.optInt("season", 0)?.takeIf { it > 0 }
        val number = episode?.optInt("number", 0)?.takeIf { it > 0 }
        if (series && (season == null || number == null)) return null
        val anchor = imdb ?: "tmdb:$tmdb"
        val videoId = if (series) "$anchor:$season:$number" else anchor
        return WatchedItem(
            ref = MediaRef(
                isSeries = series,
                imdb = imdb,
                tmdb = tmdb,
                season = season,
                episode = number,
                title = media.optString("title").takeIf { it.isNotBlank() },
                year = media.optInt("year", 0).takeIf { it > 0 },
            ),
            watchedAt = watchedAt,
            videoId = videoId,
        )
    }
}
