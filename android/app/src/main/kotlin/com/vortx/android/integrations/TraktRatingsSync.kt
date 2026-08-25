package com.vortx.android.integrations

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.model.MediaRef
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/** WHY provider-rating audit row: write ratings to Trakt and read them back into an idempotent local cache. */
internal object TraktRatingsSync {
    private const val TAG = "TraktRatingsSync"
    private const val PREFS_FILE = "vortx_trakt_ratings"
    private const val RATINGS_KEY = "ratings"
    private val lock = Mutex()
    @Volatile private var prefs: SharedPreferences? = null

    data class Rating(val ref: MediaRef, val value: Int, val ratedAt: String)

    /** Optional future local user-rating store seam. The current Android rating stores are critic-display-only. */
    @Volatile var localSnapshot: suspend () -> List<Rating> = { emptyList() }

    fun init(context: Context) {
        if (prefs == null) synchronized(this) {
            if (prefs == null) prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        }
    }

    suspend fun sync(): Int {
        if (!enabled()) return 0
        for (rating in runCatching { localSnapshot() }.getOrDefault(emptyList())) push(rating)
        val response = TraktSyncSupport.request("GET", "/sync/ratings")
        if (!response.isSuccess) {
            Log.d(TAG, "trakt ratings pull skipped: HTTP ${response.status}")
            return 0
        }
        val array = runCatching { JSONArray(response.body) }.getOrNull() ?: return 0
        var merged = 0
        lock.withLock {
            val cache = readCache()
            for (index in 0 until array.length()) {
                val parsed = parse(array.optJSONObject(index)) ?: continue
                val key = key(parsed.ref)
                val old = cache.optJSONObject(key)
                val oldAt = old?.optString("rated_at").orEmpty()
                if (old == null || oldAt < parsed.ratedAt ||
                    (oldAt == parsed.ratedAt && old.optInt("rating") != parsed.value)
                ) {
                    cache.put(key, encode(parsed))
                    merged++
                }
            }
            if (merged > 0) prefs?.edit()?.putString(RATINGS_KEY, cache.toString())?.apply()
        }
        Log.d(TAG, "trakt ratings sync: pulled=${array.length()} merged=$merged")
        return merged
    }

    /** Event hook for the future Android user-rating mutation seam. Trakt upsert makes repeats idempotent. */
    suspend fun ratingChanged(rating: Rating): Boolean = if (enabled()) push(rating) else false

    suspend fun cachedRating(ref: MediaRef): Rating? = lock.withLock {
        readCache().optJSONObject(key(ref))?.let { decode(ref, it) }
    }

    private fun enabled(): Boolean = TraktAuth.isSignedIn &&
        ScrobbleService.isToggleOn(ScrobbleService.KEY_TRAKT_RATINGS, true)

    private suspend fun push(rating: Rating): Boolean {
        val bucket = if (rating.ref.isSeries) "shows" else "movies"
        val item = JSONObject()
            .put("rating", rating.value.coerceIn(1, 10))
            .put("rated_at", rating.ratedAt)
            .put("ids", ids(rating.ref))
        val body = JSONObject().put(bucket, JSONArray().put(item)).toString()
        val response = TraktSyncSupport.request("POST", "/sync/ratings", body)
        if (!response.isSuccess) {
            Log.d(TAG, "trakt ratings push skipped: HTTP ${response.status}")
            return false
        }
        lock.withLock {
            val cache = readCache()
            val key = key(rating.ref)
            val oldAt = cache.optJSONObject(key)?.optString("rated_at").orEmpty()
            if (oldAt <= rating.ratedAt) {
                cache.put(key, encode(rating))
                prefs?.edit()?.putString(RATINGS_KEY, cache.toString())?.apply()
            }
        }
        return true
    }

    private fun parse(root: JSONObject?): Rating? {
        root ?: return null
        val media = root.optJSONObject("movie") ?: root.optJSONObject("show") ?: return null
        val ids = media.optJSONObject("ids") ?: return null
        val imdb = ids.optString("imdb").takeIf { it.startsWith("tt") }
        val tmdb = ids.optInt("tmdb", 0).takeIf { it > 0 }
        if (imdb == null && tmdb == null) return null
        val value = root.optInt("rating", 0).takeIf { it in 1..10 } ?: return null
        val ratedAt = root.optString("rated_at").takeIf { it.isNotBlank() } ?: return null
        return Rating(MediaRef(root.has("show"), imdb, tmdb, title = media.optString("title")), value, ratedAt)
    }

    private fun ids(ref: MediaRef) = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotBlank() }?.let { put("imdb", it) }
        ref.tmdb?.let { put("tmdb", it) }
    }

    private fun key(ref: MediaRef): String =
        "${if (ref.isSeries) "show" else "movie"}:${ref.imdb ?: "tmdb:${ref.tmdb}"}"

    private fun encode(rating: Rating) = JSONObject()
        .put("rating", rating.value)
        .put("rated_at", rating.ratedAt)
        .put("series", rating.ref.isSeries)
        .put("imdb", rating.ref.imdb)
        .put("tmdb", rating.ref.tmdb)

    private fun decode(ref: MediaRef, root: JSONObject): Rating? {
        val value = root.optInt("rating", 0).takeIf { it in 1..10 } ?: return null
        return Rating(ref, value, root.optString("rated_at"))
    }

    private fun readCache(): JSONObject = runCatching {
        JSONObject(prefs?.getString(RATINGS_KEY, null) ?: "{}")
    }.getOrDefault(JSONObject())
}
