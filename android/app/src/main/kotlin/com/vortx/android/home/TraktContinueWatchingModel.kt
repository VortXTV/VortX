package com.vortx.android.home

import com.vortx.android.catalog.CatalogTmdbEdge
import com.vortx.android.catalog.optStringOrNull
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/** A separately-owned, read-only Trakt paused-playback row. It never alters engine progress. */
internal const val TRAKT_CONTINUE_WATCHING_CATALOG_ID = "vortx.home.traktContinueWatching"

internal data class TraktContinueWatchingRefresh(val items: List<MetaItem>, val changed: Boolean)

internal interface TraktContinueWatchingSource {
    fun sessionEpoch(): Long?
    fun isEnabled(): Boolean
    suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>>
}

/** Complete, exact-session snapshot; failed refreshes retain the last successful snapshot. */
internal class TraktContinueWatchingModel(
    private val source: TraktContinueWatchingSource = TraktPlaybackSource,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private var epoch: Long? = null
    private var revision = 0L
    private var lastSuccessAt: Long? = null
    private var cached: List<MetaItem> = emptyList()

    suspend fun refresh(allowOwner: Boolean): TraktContinueWatchingRefresh = mutex.withLock {
        val before = cached
        val expected = source.sessionEpoch()
        if (!allowOwner || !source.isEnabled() || expected == null) {
            reset(null)
            return TraktContinueWatchingRefresh(emptyList(), before.isNotEmpty())
        }
        if (epoch != expected) reset(expected)
        if (lastSuccessAt?.let { nowMillis() - it < REFRESH_INTERVAL_MS } == true) {
            return TraktContinueWatchingRefresh(cached, before != cached)
        }
        val capturedRevision = revision
        val response = source.fetch(expected)
        if (capturedRevision != revision || source.sessionEpoch() != expected || !source.isEnabled()) {
            if (source.sessionEpoch() != expected || !source.isEnabled()) reset(null)
            return TraktContinueWatchingRefresh(cached, before != cached)
        }
        response.onSuccess { cached = it; lastSuccessAt = nowMillis() }
        TraktContinueWatchingRefresh(cached, before != cached)
    }

    suspend fun clear() = mutex.withLock { reset(null) }

    private fun reset(nextEpoch: Long?) {
        revision += 1
        epoch = nextEpoch
        lastSuccessAt = null
        cached = emptyList()
    }

    private companion object { const val REFRESH_INTERVAL_MS = 5 * 60 * 1000L }
}

/** Insert after native Continue Watching before Home preferences arrange client rails. */
internal fun withTraktContinueWatchingRail(rows: List<Catalog>, items: List<MetaItem>): List<Catalog> {
    val base = rows.filterNot { it.id == TRAKT_CONTINUE_WATCHING_CATALOG_ID }
    if (items.isEmpty()) return base
    val index = (base.indexOfFirst { it.id == HomeRail.CONTINUE_CATALOG_ID } + 1).coerceAtLeast(0)
    return base.toMutableList().apply {
        add(index.coerceAtMost(size), Catalog(
            id = TRAKT_CONTINUE_WATCHING_CATALOG_ID,
            title = "Continue Watching from Trakt",
            items = items,
            // Trakt playback-record ids are not engine identities: do not expose a local dismiss action.
            readOnly = true,
        ))
    }
}

/** Authenticated, refreshed-token, exact-session adapter. Both legs must succeed before a replace. */
private object TraktPlaybackSource : TraktContinueWatchingSource {
    override fun sessionEpoch(): Long? = TraktAuth.currentSessionEpoch
    override fun isEnabled(): Boolean = ScrobbleService.isToggleOn(
        ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING, false,
    )

    override suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>> = preservingCancellation {
        val movies = TraktAuth.sessionBoundGet("/sync/playback/movies?extended=full", expectedEpoch)
            ?: error("Trakt session changed")
        val episodes = TraktAuth.sessionBoundGet("/sync/playback/episodes?extended=full", expectedEpoch)
            ?: error("Trakt session changed")
        check(movies.status in 200..299) { "Trakt movies HTTP ${movies.status}" }
        check(episodes.status in 200..299) { "Trakt episodes HTTP ${episodes.status}" }
        val seeds = foldTraktContinueWatching(
            JSONArray(movies.body).toObjects() + JSONArray(episodes.body).toObjects(),
        )
        coroutineScope { seeds.map { seed -> async { TraktPlaybackArtwork.resolve(seed) } }.awaitAll() }
    }
}

/** Series rows retain their latest episode in the caption, but resolve/open by the show identity. */
internal data class TraktContinueWatchingSeed(
    val id: String,
    val type: MediaType,
    val name: String,
    val progress: Float,
    val pausedAt: String,
    val tmdbId: Int?,
    val imdbId: String?,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeName: String? = null,
)

/** Newest valid pause wins; exact type/id duplicates cannot produce duplicate cards. */
internal fun foldTraktContinueWatching(rows: List<JSONObject>): List<TraktContinueWatchingSeed> {
    val byIdentity = linkedMapOf<String, TraktContinueWatchingSeed>()
    rows.mapNotNull(::traktSeed).sortedByDescending(TraktContinueWatchingSeed::pausedAt).forEach { seed ->
        byIdentity.putIfAbsent("${seed.type.id}|${seed.id}", seed)
    }
    return byIdentity.values.toList()
}

private fun traktSeed(row: JSONObject): TraktContinueWatchingSeed? {
    val progress = row.optDouble("progress", Double.NaN)
    if (!progress.isFinite() || progress <= 0.0 || progress >= 95.0) return null
    val pausedAt = row.optString("paused_at").takeIf(String::isNotBlank) ?: return null
    val episode = row.optJSONObject("episode")
    val isEpisode = row.optString("type") == "episode" || episode != null
    val media = row.optJSONObject(if (isEpisode) "show" else "movie") ?: return null
    val ids = media.optJSONObject("ids") ?: return null
    val imdb = ids.optString("imdb").takeIf(::isImdbId)
    val tmdb = ids.optInt("tmdb", 0).takeIf { it > 0 }
    val type = if (isEpisode) MediaType.SERIES else MediaType.MOVIE
    val id = imdb ?: tmdb?.let { if (isEpisode) "tmdb:tv:$it" else "tmdb:movie:$it" } ?: return null
    val season = if (isEpisode) episode?.optInt("season", -1)?.takeIf { it >= 0 } else null
    val number = if (isEpisode) episode?.optInt("number", 0)?.takeIf { it > 0 } else null
    if (isEpisode && (season == null || number == null)) return null
    return TraktContinueWatchingSeed(
        id = id, type = type, name = media.optString("title").takeIf(String::isNotBlank) ?: id,
        progress = progress.toFloat(), pausedAt = pausedAt, tmdbId = tmdb, imdbId = imdb,
        season = season, episode = number, episodeName = episode?.optString("title")?.takeIf(String::isNotBlank),
    )
}

/** Reuses the signed TMDB edge. Episodes use the typed TV path and prefer their still over the show backdrop. */
private object TraktPlaybackArtwork {
    suspend fun resolve(seed: TraktContinueWatchingSeed): MetaItem {
        val tmdb = seed.tmdbId ?: resolveTmdb(seed) ?: return fallback(seed)
        val media = if (seed.type == MediaType.SERIES) "tv" else "movie"
        val detail = CatalogTmdbEdge.getJson("/$media/$tmdb")
        val episode = if (media == "tv" && seed.season != null && seed.episode != null) {
            CatalogTmdbEdge.getJson("/tv/$tmdb/season/${seed.season}/episode/${seed.episode}")
        } else null
        val poster = detail?.optStringOrNull("poster_path")?.let { "${CatalogTmdbEdge.IMAGE_BASE}/w342$it" }
        val backdrop = episode?.optStringOrNull("still_path") ?: detail?.optStringOrNull("backdrop_path")
        return fallback(seed).copy(
            poster = poster,
            background = backdrop?.let { "${CatalogTmdbEdge.IMAGE_BASE}/w780$it" },
            year = detail?.optStringOrNull(if (media == "tv") "first_air_date" else "release_date")?.take(4),
        )
    }

    private suspend fun resolveTmdb(seed: TraktContinueWatchingSeed): Int? {
        val imdb = seed.imdbId ?: return null
        val results = CatalogTmdbEdge.getJson("/find/$imdb?external_source=imdb_id") ?: return null
        val key = if (seed.type == MediaType.SERIES) "tv_results" else "movie_results"
        return results.optJSONArray(key)?.optJSONObject(0)?.optInt("id", 0)?.takeIf { it > 0 }
    }

    private fun fallback(seed: TraktContinueWatchingSeed) = MetaItem(
        id = seed.id, type = seed.type, name = seed.name, progress = (seed.progress / 100f).coerceIn(0f, 1f),
        caption = if (seed.type == MediaType.SERIES) {
            "S${seed.season} E${seed.episode}" + seed.episodeName?.let { " · $it" }.orEmpty()
        } else null,
    )
}

private fun JSONArray.toObjects(): List<JSONObject> = buildList {
    for (index in 0 until length()) optJSONObject(index)?.let(::add)
}

private fun isImdbId(value: String): Boolean =
    value.startsWith("tt") && value.drop(2).length >= 6 && value.drop(2).all(Char::isDigit)

private suspend inline fun <T> preservingCancellation(block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (error: Throwable) {
    Result.failure(error)
}
