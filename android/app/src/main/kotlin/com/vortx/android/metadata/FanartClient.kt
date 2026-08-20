package com.vortx.android.metadata

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Resolves and caches fanart.tv artwork (clearlogo, clearart, poster, background) by id, INDEPENDENT of
 * ERDB. Kotlin port of Apple `app/SourcesShared/FanartClient.swift`. Calls the fanart.tv public v3 API
 * directly with the user's fanart.tv key ([ArtworkPreferences.fanartKey]) so users get fanart art WITHOUT
 * enabling ERDB (which replaces every poster with a rating-baked render). Fail-soft: any miss / parse /
 * network error or a missing key returns empty art and the caller keeps its existing artwork. One lookup
 * per id (cached + in-flight deduped), mirroring the Apple actor.
 *
 * id mapping: fanart.tv movies accept an IMDb `tt` id OR a TMDB numeric id; fanart.tv TV is keyed by TVDB
 * id only, so a `tt`/`tmdb` series is mapped to its TVDB id via TMDB (needs a TMDB key, else TV fails soft).
 *
 * SECURITY (same as Apple): the fanart.tv and TMDB request URLs carry the user's key as a query value.
 * They are NEVER logged (no URL string ever reaches a diagnostic sink here); the key is a user credential.
 */
object FanartClient {

    /** The resolved fanart.tv art bundle for a title (any field may be null). Apple `FanartClient.Art`. */
    data class Art(
        val logo: String? = null,
        val clearart: String? = null,
        val poster: String? = null,
        val background: String? = null,
    ) {
        val isEmpty: Boolean get() = logo == null && clearart == null && poster == null && background == null
    }

    private const val TIMEOUT_MS = 8_000

    private val lock = Mutex()
    private val cache = HashMap<String, Art>()
    private val inflight = HashMap<String, CompletableDeferred<Art>>()

    /** The resolved fanart.tv art bundle for a title, or empty art when fanart has none / no key. */
    suspend fun art(id: String, type: String): Art {
        // Cached or already-in-flight: dedupe under the lock, but AWAIT the shared deferred OUTSIDE the lock
        // (awaiting while holding the mutex would block the owner's completion write and deadlock). The
        // owning coroutine is the one that created the deferred; every concurrent caller awaits it.
        val owned = CompletableDeferred<Art>()
        val existing: CompletableDeferred<Art>? = lock.withLock {
            cache[id]?.let { return it }
            val inFlight = inflight[id]
            if (inFlight != null) {
                inFlight
            } else {
                inflight[id] = owned
                null
            }
        }
        if (existing != null) return existing.await()

        val result = fetch(id, type)
        lock.withLock {
            if (!result.isEmpty) cache[id] = result   // don't latch a transient failure into a session-long empty
            inflight.remove(id)
        }
        owned.complete(result)
        return result
    }

    // MARK: fetch

    private suspend fun fetch(id: String, type: String): Art {
        val key = ArtworkPreferences.fanartKey() ?: return Art()
        if (key.isEmpty()) return Art()
        val isTV = type == "series" || type == "tv"
        return if (isTV) {
            val tvdb = tvdbID(id) ?: return Art()
            fetchObject("tv", tvdb, key, tv = true)
        } else {
            val movie = movieID(id) ?: return Art()
            fetchObject("movies", movie, key, tv = false)
        }
    }

    /** fanart.tv movies accept an IMDb `tt` id OR a TMDB numeric id; map the engine id to one of those. */
    private fun movieID(id: String): String? = when {
        id.startsWith("tt") -> id
        id.startsWith("tmdb:") -> id.substringAfterLast(":")   // tmdb:movie:603 -> 603
        else -> null
    }

    /** fanart.tv TV is keyed by TVDB id only. `tvdb:` maps directly; `tt`/`tmdb` series resolve via TMDB. */
    private suspend fun tvdbID(id: String): String? {
        if (id.startsWith("tvdb:")) return id.substringAfterLast(":")
        val tmdbKey = ArtworkPreferences.tmdbKey()?.takeIf { it.isNotEmpty() } ?: return null
        var tmdbTVID: String? = null
        if (id.startsWith("tt")) {
            val obj = getJSON(
                "https://api.themoviedb.org/3/find/$id?api_key=$tmdbKey&external_source=imdb_id",
            )
            val tv = obj?.optJSONArray("tv_results")?.optJSONObject(0)
            val tid = tv?.let { if (it.has("id")) it.optInt("id") else null }
            if (tid != null) tmdbTVID = tid.toString()
        } else if (id.startsWith("tmdb:")) {
            tmdbTVID = id.substringAfterLast(":")
        }
        val resolved = tmdbTVID ?: return null
        val ext = getJSON("https://api.themoviedb.org/3/tv/$resolved/external_ids?api_key=$tmdbKey") ?: return null
        if (!ext.has("tvdb_id") || ext.isNull("tvdb_id")) return null
        return ext.optInt("tvdb_id").toString()
    }

    private suspend fun fetchObject(path: String, id: String, key: String, tv: Boolean): Art {
        val obj = getJSON("https://webservice.fanart.tv/v3/$path/$id?api_key=$key") ?: return Art()
        return if (tv) {
            Art(
                logo = best(obj.opt("hdtvlogo") ?: obj.opt("clearlogo")),
                clearart = best(obj.opt("hdclearart") ?: obj.opt("clearart")),
                poster = best(obj.opt("tvposter")),
                background = best(obj.opt("showbackground")),
            )
        } else {
            Art(
                logo = best(obj.opt("hdmovielogo") ?: obj.opt("movielogo")),
                clearart = best(obj.opt("hdmovieclearart") ?: obj.opt("movieart")),
                poster = best(obj.opt("movieposter")),
                background = best(obj.opt("moviebackground")),
            )
        }
    }

    /** fanart.tv art arrays are `[{url, lang, likes}]`; prefer English, then the most-liked. Apple `best`. */
    private fun best(raw: Any?): String? {
        val arr = raw as? JSONArray ?: return null
        if (arr.length() == 0) return null
        val rows = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        val ranked = rows.sortedWith(
            compareByDescending<JSONObject> { it.optString("lang") == "en" }
                .thenByDescending { it.optString("likes", "0").toIntOrNull() ?: 0 },
        )
        return ranked.firstOrNull()?.optString("url")?.takeIf { it.isNotEmpty() }
    }

    private suspend fun getJSON(urlString: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = true   // art mappings are immutable: prefer the shared cache (Apple returnCacheDataElseLoad)
            }
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }
}
