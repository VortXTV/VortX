package com.vortx.android.account

import com.vortx.android.BuildConfig
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.MediaType
import com.vortx.android.engine.NativeLibraryMirrorOrigin
import com.vortx.android.integrations.DurableProviderMirrorCredential
import com.vortx.android.integrations.DurableProviderPost
import com.vortx.android.integrations.ProviderMirrorResult
import com.vortx.android.integrations.ProviderMirrorTransport
import com.vortx.android.integrations.ProviderWatchlistReceipt
import com.vortx.android.integrations.result
import com.vortx.android.sync.ProviderRetryDispatchOutcome
import com.vortx.android.sync.ProviderRetryOutbox
import com.vortx.android.sync.ProviderRetryStart
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.CancellationException
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

internal fun ProviderRetryOutbox.Provider.watchlistOperation(add: Boolean): ProviderWatchlistReceipt.Operation? = when (this) {
    ProviderRetryOutbox.Provider.TRAKT -> if (add) ProviderWatchlistReceipt.Operation.TRAKT_ADD else ProviderWatchlistReceipt.Operation.TRAKT_REMOVE
    ProviderRetryOutbox.Provider.SIMKL -> if (add) ProviderWatchlistReceipt.Operation.SIMKL_ADD else null
}

internal fun providerWatchlistUrl(operation: ProviderWatchlistReceipt.Operation): String = when (operation) {
    ProviderWatchlistReceipt.Operation.TRAKT_ADD -> "${TraktAuth.API_BASE}/sync/watchlist"
    ProviderWatchlistReceipt.Operation.TRAKT_REMOVE -> "${TraktAuth.API_BASE}/sync/watchlist/remove"
    ProviderWatchlistReceipt.Operation.SIMKL_ADD -> "${SIMKLAuth.API_BASE}/sync/add-to-list?${SIMKLAuth.requiredQuery()}"
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
 * A fresh request uses its original native origin and provider epoch. Durable work needs an original
 * start marker, current credential proof and a response that settles that exact submitted title.
 */
internal object AccountWatchlistClient {

    private val traktClientId: String get() = BuildConfig.TRAKT_CLIENT_ID.trim()
    private val durableImdb = Regex("tt[0-9]{1,20}")

    /** Call before minting a start. Multi-ID and unknown-media rows cannot be settled by this wire. */
    fun isDurableWatchlistSupported(provider: ProviderRetryOutbox.Provider, add: Boolean, ref: TitleRef): Boolean {
        if (ref.isSeries == null || provider.watchlistOperation(add) == null) return false
        val imdb = ref.imdb
        return if (imdb != null) ref.tmdb == null && durableImdb.matches(imdb) else (ref.tmdb ?: 0) > 0
    }

    /** The retry caller owns the original session, start and prepared existing-only credential. */
    suspend fun dispatchDurable(
        lane: ProviderRetryOutbox.Lane,
        row: ProviderRetryOutbox.Row,
        start: ProviderRetryStart,
        owner: VortXSyncManager.ProviderRetryOwner,
        origin: NativeLibraryMirrorOrigin?,
        credential: DurableProviderMirrorCredential,
    ): ProviderRetryDispatchOutcome {
        if (start.head.lane != lane || start.head.row !== row || owner.owner != lane.owner)
            return ProviderRetryDispatchOutcome.Refused
        val ref = TitleRef(row.imdb, row.tmdb, row.isSeries)
        if (!isDurableWatchlistSupported(lane.provider, row.add, ref)) return ProviderRetryDispatchOutcome.Refused
        val receipt = checkNotNull(lane.provider.watchlistOperation(row.add))
        return when (ProviderMirrorTransport.postDurable(owner, origin, credential, start, receipt)) {
            DurableProviderPost.Refused -> ProviderRetryDispatchOutcome.Refused
            DurableProviderPost.Unsettled -> ProviderRetryDispatchOutcome.Unsettled
            DurableProviderPost.Confirmed -> ProviderRetryDispatchOutcome.Accepted(start, lane, row.operationId, row.add, ref)
        }
    }

    internal fun durableRequestHeaders(provider: ProviderRetryOutbox.Provider, bearer: String): Map<String, String> = when (provider) {
        ProviderRetryOutbox.Provider.TRAKT -> traktHeaders(bearer)
        ProviderRetryOutbox.Provider.SIMKL -> SIMKLAuth.authHeaders(bearer)
    }

    internal fun durableRequestBody(lane: ProviderRetryOutbox.Lane, row: ProviderRetryOutbox.Row): String? {
        val ref = TitleRef(row.imdb, row.tmdb, row.isSeries)
        if (!isDurableWatchlistSupported(lane.provider, row.add, ref)) return null
        return when (lane.provider) {
            ProviderRetryOutbox.Provider.TRAKT -> traktBody(ref).toString()
            ProviderRetryOutbox.Provider.SIMKL -> simklBody(ref).toString()
        }
    }

    // MARK: - Trakt

    suspend fun traktWatchlist(add: Boolean, ref: TitleRef, expectedEpoch: Long,
        origin: NativeLibraryMirrorOrigin): ProviderMirrorResult {
        if (!ref.hasUsableId) return ProviderMirrorResult.REFUSED
        val preparation = try {
            TraktAuth.prepareWatchlistCredential(origin, expectedEpoch)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) { TraktAuth.MirrorPreparation.Refused }
        val credential = when (preparation) {
            TraktAuth.MirrorPreparation.Refused -> return ProviderMirrorResult.REFUSED
            TraktAuth.MirrorPreparation.RefreshFailed -> return ProviderMirrorResult.REFRESH_FAILED
            TraktAuth.MirrorPreparation.RefreshSucceeded -> return ProviderMirrorResult.REFRESH_SUCCEEDED
            is TraktAuth.MirrorPreparation.Ready -> preparation.credential
        }
        return sendTraktWatchlist(add, ref, credential.bearer) { url, headers, body ->
            ProviderMirrorTransport.post(origin, credential.operation, credential.matches, url, headers, body)
        }.result()
    }

    private suspend fun <T> sendTraktWatchlist(add: Boolean, ref: TitleRef, token: String,
        post: suspend (String, Map<String, String>, String) -> T): T =
        post(
            providerWatchlistUrl(checkNotNull(ProviderRetryOutbox.Provider.TRAKT.watchlistOperation(add))),
            traktHeaders(token),
            traktBody(ref).toString(),
        )

    private fun traktHeaders(token: String): Map<String, String> = mapOf(
        "Content-Type" to "application/json",
        "trakt-api-version" to "2",
        "trakt-api-key" to traktClientId,
        "Authorization" to "Bearer $token",
    )

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

    suspend fun simklWatchlistAdd(ref: TitleRef, expectedEpoch: Long,
        origin: NativeLibraryMirrorOrigin): ProviderMirrorResult {
        if (!ref.hasUsableId) return ProviderMirrorResult.REFUSED
        val credential = runCatching { SIMKLAuth.validWatchlistCredential(origin.expectedAccount, expectedEpoch) }.getOrNull()
            ?: return ProviderMirrorResult.REFUSED
        return sendSimklWatchlistAdd(ref, credential.bearer) { url, headers, body ->
            ProviderMirrorTransport.post(origin, credential.operation, credential.matches, url, headers, body)
        }.result()
    }

    private suspend fun <T> sendSimklWatchlistAdd(ref: TitleRef, token: String,
        post: suspend (String, Map<String, String>, String) -> T): T = post(
        providerWatchlistUrl(ProviderWatchlistReceipt.Operation.SIMKL_ADD),
        SIMKLAuth.authHeaders(token),
        simklBody(ref).toString(),
    )

    private fun simklBody(ref: TitleRef): JSONObject {
        val item = JSONObject().apply {
            put("ids", simklIds(ref))
            put("to", "plantowatch")
        }
        return JSONObject().put(
            if (ref.isSeries == true) "shows" else "movies",
            JSONArray().put(item),
        )
    }

    private fun simklIds(ref: TitleRef): JSONObject = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotEmpty() }?.let { put("imdb", it) }
        // SIMKL wants tmdb as a JSON number, exactly as the Apple SIMKLIDs encoder emits it.
        ref.tmdb?.let { put("tmdb", it) }
    }
}
