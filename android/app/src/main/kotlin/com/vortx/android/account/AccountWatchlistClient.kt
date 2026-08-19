package com.vortx.android.account

import com.vortx.android.BuildConfig
import com.vortx.android.integrations.IntegrationsHttp
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.MediaType
import org.json.JSONArray
import org.json.JSONObject

/**
 * A provider-agnostic title identity for the watchlist write leg: the IMDb `tt…` id and/or the numeric
 * TMDB id, plus whether the title is a series. [isSeries] is null when the caller could not tell (the
 * bare-id library-remove path, [com.vortx.android.data.CatalogRepository.removeFromLibrary]); a Trakt
 * remove then targets BOTH the movies and shows arrays, which Trakt resolves by matching the id in
 * whichever list the title truly belongs to and reporting the other as `not_found` (never a wrong delete).
 */
internal data class TitleRef(
    val imdb: String?,
    val tmdb: Int?,
    val isSeries: Boolean?,
) {
    val hasUsableId: Boolean get() = !imdb.isNullOrEmpty() || tmdb != null

    companion object {
        /**
         * Build from a Stremio engine meta id (`tt1234567`, `tt1234567:1:2`, `tmdb:12345`, `tmdb:12345:1:2`)
         * and an optional [MediaType]. Reuses the exact id shapes the scrobble path recognizes; a magnet /
         * kitsu-only id (neither imdb nor tmdb) yields a ref with [hasUsableId] false, so the caller skips it.
         */
        fun from(id: String, type: MediaType?): TitleRef = TitleRef(
            imdb = parseImdbId(id),
            tmdb = parseTmdbId(id),
            isSeries = type?.let { it == MediaType.SERIES },
        )

        private fun parseImdbId(metaId: String): String? {
            val head = metaId.substringBefore(':')
            return head.takeIf { it.startsWith("tt") && it.length > 2 && it.drop(2).all(Char::isDigit) }
        }

        private fun parseTmdbId(metaId: String): Int? {
            if (!metaId.startsWith("tmdb:")) return null
            return metaId.removePrefix("tmdb:").substringBefore(':').toIntOrNull()
        }
    }
}

/**
 * The authenticated Trakt + SIMKL WATCHLIST write wire, the account-mutating half of two-way watchlist
 * sync (the READ half - remote watchlist -> home rails - already lives in
 * [com.vortx.android.home.ExternalWatchlistModels]). Endpoints and payloads match the Apple
 * `TraktService` / `SIMKLService` byte for byte:
 *
 *   - Trakt add:    `POST /sync/watchlist`          body `{ movies|shows: [ { ids: { imdb, tmdb } } ] }`
 *   - Trakt remove: `POST /sync/watchlist/remove`   same body
 *   - SIMKL add:    `POST /sync/add-to-list`        body `{ movies|shows: [ { ids, to: "plantowatch" } ] }`
 *   - SIMKL remove: NONE. SIMKL has no watchlist-remove endpoint, so a library-remove is a no-op there
 *                   (Apple `SIMKLProvider.removeFromWatchlist` is likewise a no-op). It must NEVER be
 *                   routed to `/sync/history/remove`, which deletes watch HISTORY, not the plan-to-watch.
 *   - SIMKL anime rides the `shows` array on every write, exactly as Apple does.
 *
 * SESSION-BOUND: the caller captures the provider's session epoch before any suspend and passes it as
 * [expectedEpoch]; a request whose live token/session no longer matches is dropped before it is sent, so
 * one account's library change can never move through another account's credentials. Every method returns
 * true only on a real 2xx; a transport failure (status 0), an auth error, or any non-2xx returns false so
 * the caller can queue an offline retry. Nothing here logs a token.
 */
internal object AccountWatchlistClient {

    private val traktClientId: String get() = BuildConfig.TRAKT_CLIENT_ID.trim()

    // MARK: - Trakt

    /**
     * `POST /sync/watchlist` (add) or `/sync/watchlist/remove`. Skips when not signed in, the session
     * moved, or the token cannot be refreshed. Returns true only on a 2xx.
     */
    suspend fun traktWatchlist(add: Boolean, ref: TitleRef, expectedEpoch: Long): Boolean {
        if (!ref.hasUsableId || !TraktAuth.isSignedIn) return false
        if (TraktAuth.currentSessionEpoch != expectedEpoch) return false
        val token = runCatching { TraktAuth.validToken() }.getOrNull() ?: return false
        if (TraktAuth.currentSessionEpoch != expectedEpoch) return false
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "${TraktAuth.API_BASE}${if (add) "/sync/watchlist" else "/sync/watchlist/remove"}",
            headers = mapOf(
                "Content-Type" to "application/json",
                "trakt-api-version" to "2",
                "trakt-api-key" to traktClientId,
                "Authorization" to "Bearer $token",
            ),
            body = traktBody(ref).toString(),
        )
        return response.isSuccess
    }

    /**
     * `{ movies: [ { ids } ] }` for a movie, `{ shows: [ { ids } ] }` for a series. When [TitleRef.isSeries]
     * is unknown (the bare-id remove) the ids go into BOTH arrays; Trakt removes from whichever list the
     * title actually belongs to and ignores the other.
     */
    private fun traktBody(ref: TitleRef): JSONObject {
        val ids = traktIds(ref)
        val entry = JSONArray().put(JSONObject().put("ids", ids))
        return JSONObject().apply {
            when (ref.isSeries) {
                true -> put("shows", entry)
                false -> put("movies", entry)
                null -> {
                    put("movies", entry)
                    put("shows", JSONArray().put(JSONObject().put("ids", traktIds(ref))))
                }
            }
        }
    }

    private fun traktIds(ref: TitleRef): JSONObject = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotEmpty() }?.let { put("imdb", it) }
        ref.tmdb?.let { put("tmdb", it) }
    }

    // MARK: - SIMKL

    /**
     * `POST /sync/add-to-list` with `to: "plantowatch"`. Series and anime both ride the `shows` array
     * (Apple's shape). SIMKL has no watchlist-remove, so [simklWatchlistAdd] is the only SIMKL write here.
     */
    suspend fun simklWatchlistAdd(ref: TitleRef, expectedEpoch: Long): Boolean {
        if (!ref.hasUsableId || !SIMKLAuth.isSignedIn) return false
        if (SIMKLAuth.currentSessionEpoch != expectedEpoch) return false
        val token = runCatching { SIMKLAuth.validToken() }.getOrNull() ?: return false
        if (SIMKLAuth.currentSessionEpoch != expectedEpoch) return false
        val item = JSONObject().apply {
            put("ids", simklIds(ref))
            put("to", "plantowatch")
        }
        val body = JSONObject().put(
            if (ref.isSeries == true) "shows" else "movies",
            JSONArray().put(item),
        )
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "${SIMKLAuth.API_BASE}/sync/add-to-list?${SIMKLAuth.requiredQuery()}",
            headers = SIMKLAuth.authHeaders(token),
            body = body.toString(),
        )
        return response.isSuccess
    }

    private fun simklIds(ref: TitleRef): JSONObject = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotEmpty() }?.let { put("imdb", it) }
        // SIMKL wants tmdb as a JSON number, exactly as the Apple SIMKLIDs encoder emits it.
        ref.tmdb?.let { put("tmdb", it) }
    }
}
