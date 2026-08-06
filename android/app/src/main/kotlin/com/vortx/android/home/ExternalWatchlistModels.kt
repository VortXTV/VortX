package com.vortx.android.home

import android.content.Context
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.trickplay.TmdbImdbResolver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal const val TRAKT_WATCHLIST_CATALOG_ID = "vortx.home.traktWatchlist"
internal const val SIMKL_WATCHLIST_CATALOG_ID = "vortx.home.simklWatchlist"

internal data class ExternalRailRefresh(val items: List<MetaItem>, val changed: Boolean)

internal interface ExternalWatchlistSource {
    fun sessionEpoch(): Long?
    suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>>
}

/** Exact-account, throttled, fail-soft state for one read-only external watchlist rail. */
internal open class ExternalWatchlistModel(
    private val source: ExternalWatchlistSource,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val refreshMutex = Mutex()
    private val stateLock = Any()
    private var revision = 0L
    private var sessionEpoch: Long? = null
    private var lastSuccessAt: Long? = null
    private var cachedItems: List<MetaItem> = emptyList()

    suspend fun refresh(): ExternalRailRefresh = refreshMutex.withLock { refreshLocked() }

    private suspend fun refreshLocked(): ExternalRailRefresh {
        val expected = source.sessionEpoch()
        val plan = synchronized(stateLock) {
            val visibleBefore = cachedItems
            if (expected == null) {
                resetLocked(null)
                return ExternalRailRefresh(emptyList(), visibleBefore.isNotEmpty())
            }
            if (sessionEpoch != expected) resetLocked(expected)
            val last = lastSuccessAt
            if (last != null && nowMillis() - last < REFRESH_INTERVAL_MS) {
                return ExternalRailRefresh(cachedItems, visibleBefore != cachedItems)
            }
            FetchPlan(expected, visibleBefore, revision)
        }

        val result = source.fetch(plan.expectedEpoch)
        return synchronized(stateLock) {
            // A boundary clear during network I/O wins. Never republish its stale response afterward.
            if (revision != plan.revision) {
                return@synchronized ExternalRailRefresh(cachedItems, plan.visibleBefore != cachedItems)
            }
            if (source.sessionEpoch() != plan.expectedEpoch) {
                resetLocked(null)
                return@synchronized ExternalRailRefresh(emptyList(), plan.visibleBefore.isNotEmpty())
            }
            result.onSuccess { items ->
                cachedItems = items
                lastSuccessAt = nowMillis()
            }
            ExternalRailRefresh(cachedItems, plan.visibleBefore != cachedItems)
        }
    }

    fun clear() = synchronized(stateLock) { resetLocked(null) }

    private fun resetLocked(nextSession: Long?) {
        revision += 1
        sessionEpoch = nextSession
        lastSuccessAt = null
        cachedItems = emptyList()
    }

    private data class FetchPlan(
        val expectedEpoch: Long,
        val visibleBefore: List<MetaItem>,
        val revision: Long,
    )

    private companion object {
        const val REFRESH_INTERVAL_MS = 5 * 60 * 1000L
    }
}

internal class TraktRailsModel(
    source: ExternalWatchlistSource = TraktWatchlistSource,
    nowMillis: () -> Long = System::currentTimeMillis,
) : ExternalWatchlistModel(source, nowMillis)

internal class SimklRailsModel(
    context: Context? = null,
    source: ExternalWatchlistSource = SimklWatchlistSource(context),
    nowMillis: () -> Long = System::currentTimeMillis,
) : ExternalWatchlistModel(source, nowMillis)

internal fun withExternalWatchlistRails(
    rows: List<Catalog>,
    trakt: List<MetaItem>,
    simkl: List<MetaItem>,
): List<Catalog> {
    val base = rows.filterNot { it.id == TRAKT_WATCHLIST_CATALOG_ID || it.id == SIMKL_WATCHLIST_CATALOG_ID }
    if (trakt.isEmpty() && simkl.isEmpty()) return base
    val insertion = (base.indexOfFirst { it.id == TOP_PICKS_CATALOG_ID } + 1).coerceAtLeast(0)
    return base.toMutableList().apply {
        var index = insertion
        if (trakt.isNotEmpty()) add(index++, Catalog(TRAKT_WATCHLIST_CATALOG_ID, "Trakt Watchlist", trakt))
        if (simkl.isNotEmpty()) add(index, Catalog(SIMKL_WATCHLIST_CATALOG_ID, "SIMKL Watchlist", simkl))
    }
}

private data class ExternalSeed(
    val imdb: String,
    val type: MediaType,
    val title: String,
    val addedAt: String? = null,
)

private data class SimklSeed(
    val imdb: String?,
    val tmdb: String?,
    val type: MediaType,
    val title: String,
    val addedAt: String?,
)

private object TraktWatchlistSource : ExternalWatchlistSource {
    override fun sessionEpoch(): Long? = TraktAuth.currentSessionEpoch

    override suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>> = preservingCancellation {
        val response = TraktAuth.sessionBoundGet("/sync/watchlist", expectedEpoch)
            ?: error("Trakt session changed")
        check(response.status in 200..299) { "Trakt watchlist HTTP ${response.status}" }
        val body = JSONArray(response.body)
        val seen = hashSetOf<String>()
        val seeds = buildList {
            for (index in 0 until body.length()) {
                val row = body.optJSONObject(index) ?: continue
                val isSeries = row.optString("type") == "show"
                val media = row.optJSONObject(if (isSeries) "show" else "movie") ?: continue
                val imdb = media.optJSONObject("ids")?.optString("imdb")
                    ?.takeIf(::isImdbId) ?: continue
                if (!seen.add(imdb)) continue
                val title = media.optString("title").takeIf(String::isNotBlank) ?: imdb
                add(ExternalSeed(imdb, if (isSeries) MediaType.SERIES else MediaType.MOVIE, title))
                if (size == MAX_ITEMS) break
            }
        }
        ExternalMetadataResolver.resolve(seeds)
    }
}

private class SimklWatchlistSource(private val context: Context?) : ExternalWatchlistSource {
    override fun sessionEpoch(): Long? = SIMKLAuth.currentSessionEpoch

    override suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>> = preservingCancellation {
        val rawSeeds = ArrayList<SimklSeed>(MAX_CANDIDATES)
        for ((wireType, mediaType) in TYPES) {
            val response = SIMKLAuth.sessionBoundGet(
                "/sync/all-items/$wireType/plantowatch",
                expectedEpoch,
            ) ?: error("SIMKL session changed")
            check(response.status in 200..299) { "SIMKL $wireType watchlist HTTP ${response.status}" }
            if (response.body.isBlank()) continue
            val rows = JSONObject(response.body).optJSONArray(wireType) ?: JSONArray()
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val media = row.optJSONObject(if (wireType == "movies") "movie" else "show") ?: continue
                val ids = media.optJSONObject("ids") ?: continue
                val imdb = ids.optString("imdb").takeIf(::isImdbId)
                val tmdb = tmdbString(ids.opt("tmdb"))
                if (imdb == null && tmdb == null) continue
                val title = media.optString("title").takeIf(String::isNotBlank) ?: imdb ?: "tmdb:$tmdb"
                rawSeeds += SimklSeed(
                    imdb = imdb,
                    tmdb = tmdb,
                    type = mediaType,
                    title = title,
                    addedAt = row.optString("added_to_watchlist_at").takeIf(String::isNotBlank),
                )
                if (rawSeeds.size == MAX_CANDIDATES) break
            }
        }
        val candidates = rawSeeds.sortedWith(
            compareByDescending<SimklSeed> { it.addedAt != null }.thenByDescending { it.addedAt },
        ).take(MAX_CANDIDATES)
        val resolved = coroutineScope {
            val slots = Semaphore(6)
            candidates.mapIndexed { index, seed ->
                async {
                    index to slots.withPermit {
                        val imdb = seed.imdb ?: resolveTmdb(seed.tmdb, seed.type)
                        imdb?.let { ExternalSeed(it, seed.type, seed.title, seed.addedAt) }
                    }
                }
            }.awaitAll().sortedBy { it.first }.mapNotNull { it.second }
        }
        val seen = hashSetOf<String>()
        val ordered = resolved.filter { seen.add(it.imdb) }.take(MAX_ITEMS)
        ExternalMetadataResolver.resolve(ordered)
    }

    private suspend fun resolveTmdb(tmdb: String?, type: MediaType): String? {
        val app = context?.applicationContext ?: return null
        return tmdb?.let { TmdbImdbResolver.resolveImdbId(app, "tmdb:$it", type == MediaType.SERIES) }
    }

    private fun tmdbString(raw: Any?): String? = when (raw) {
        is Number -> raw.toLong().toString()
        is String -> raw.takeIf(String::isNotBlank)
        else -> null
    }

    private companion object {
        val TYPES = listOf(
            "movies" to MediaType.MOVIE,
            "shows" to MediaType.SERIES,
            "anime" to MediaType.SERIES,
        )
    }
}

private object ExternalMetadataResolver {
    private const val CINEMETA = "https://v3-cinemeta.strem.io"
    private const val TIMEOUT_MS = 12_000
    private val slots = Semaphore(6)

    suspend fun resolve(seeds: List<ExternalSeed>): List<MetaItem> = coroutineScope {
        seeds.mapIndexed { index, seed ->
            async { index to slots.withPermit { meta(seed) } }
        }.awaitAll().sortedBy { it.first }.map { it.second }
    }

    private suspend fun meta(seed: ExternalSeed): MetaItem = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL("$CINEMETA/meta/${seed.type.id}/${seed.imdb}.json").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = true
                setRequestProperty("accept", "application/json")
            }
            if (connection.responseCode != 200) return@withContext seed.fallback()
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val meta = runCatching { JSONObject(text).optJSONObject("meta") }.getOrNull()
                ?: return@withContext seed.fallback()
            MetaItem(
                id = meta.optString("id").takeIf(::isImdbId) ?: seed.imdb,
                type = MediaType.fromId(meta.optString("type", seed.type.id)),
                name = meta.optString("name").takeIf(String::isNotBlank) ?: seed.title,
                poster = meta.optString("poster").takeIf(String::isNotBlank),
                year = meta.optString("releaseInfo").take(4).takeIf { it.length == 4 },
                description = meta.optString("description").takeIf(String::isNotBlank),
                background = meta.optString("background").takeIf(String::isNotBlank),
                imdbRating = meta.optString("imdbRating").takeIf(String::isNotBlank),
            )
        } catch (_: IOException) {
            seed.fallback()
        } finally {
            connection?.disconnect()
        }
    }

    private fun ExternalSeed.fallback() = MetaItem(id = imdb, type = type, name = title)
}

private fun isImdbId(value: String): Boolean =
    value.startsWith("tt") && value.length > 2 && value.drop(2).all(Char::isDigit)

private suspend inline fun <T> preservingCancellation(block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (error: Throwable) {
    Result.failure(error)
}

private const val MAX_ITEMS = 30
private const val MAX_CANDIDATES = MAX_ITEMS * 2
