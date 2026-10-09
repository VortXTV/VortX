package com.vortx.android.home

import com.vortx.android.catalog.CatalogTmdbEdge
import com.vortx.android.catalog.optStringOrNull
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** A separately-owned, read-only Trakt paused-playback row. It never alters engine progress. */
internal const val TRAKT_CONTINUE_WATCHING_CATALOG_ID = "vortx.home.traktContinueWatching"

/** Exact external state a Home assignment must still observe after asynchronous provider work finishes. */
internal data class TraktContinueWatchingReceipt(
    val sessionEpoch: Long?,
    val toggleRevision: Long,
)

internal data class TraktContinueWatchingRefresh(
    val items: List<MetaItem>,
    val changed: Boolean,
    val receipt: TraktContinueWatchingReceipt,
    val errorMessage: String? = null,
)

internal interface TraktContinueWatchingSource {
    fun sessionEpoch(): Long?
    fun toggleRevision(): Long
    fun isEnabled(): Boolean
    suspend fun fetch(expectedEpoch: Long): Result<List<MetaItem>>
}

/** Complete, exact-session snapshot; failed refreshes retain the last successful snapshot. */
internal class TraktContinueWatchingModel(
    private val source: TraktContinueWatchingSource = TraktPlaybackSource,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val stateLock = Any()
    private var receipt: TraktContinueWatchingReceipt? = null
    private var revision = 0L
    private var lastSuccessAt: Long? = null
    private var cached: List<MetaItem> = emptyList()
    private var errorMessage: String? = null

    /** Network/artwork work runs outside [stateLock], so [clear] invalidates immediately. */
    suspend fun refresh(allowOwner: Boolean): TraktContinueWatchingRefresh {
        val plan = synchronized(stateLock) {
            val before = cached
            val current = sourceReceipt()
            if (!allowOwner || !source.isEnabled() || current.sessionEpoch == null) {
                resetLocked(null)
                return@synchronized RefreshPlan.Immediate(snapshotLocked(before, current))
            }
            if (receipt != current) resetLocked(current)
            if (lastSuccessAt?.let { nowMillis() - it < REFRESH_INTERVAL_MS } == true) {
                return@synchronized RefreshPlan.Immediate(snapshotLocked(before, current))
            }
            RefreshPlan.Fetch(
                receipt = current,
                revision = revision,
                before = before,
            )
        }

        if (plan is RefreshPlan.Immediate) return plan.refresh
        val fetchPlan = plan as RefreshPlan.Fetch
        val response = source.fetch(requireNotNull(fetchPlan.receipt.sessionEpoch))
        return synchronized(stateLock) {
            val current = sourceReceipt()
            val sourceStillMatches = source.isEnabled() && current == fetchPlan.receipt
            if (revision != fetchPlan.revision || receipt != fetchPlan.receipt || !sourceStillMatches) {
                // This request itself is the last owner of the old cache: clear it. A newer refresh/clear
                // already advanced [revision], so never erase that newer state from a delayed old response.
                if (revision == fetchPlan.revision && receipt == fetchPlan.receipt) {
                    resetLocked(current.takeIf { source.isEnabled() && it.sessionEpoch != null })
                }
                return@synchronized snapshotLocked(fetchPlan.before, current)
            }
            response.onSuccess {
                cached = it
                lastSuccessAt = nowMillis()
                errorMessage = null
            }
            response.onFailure { errorMessage = "Couldn't refresh Trakt Continue Watching. Try again." }
            snapshotLocked(fetchPlan.before, fetchPlan.receipt)
        }
    }

    /** Synchronous invalidation: a late fetch sees its changed [revision] and cannot republish. */
    fun clear() = synchronized(stateLock) { resetLocked(null) }

    private fun sourceReceipt() = TraktContinueWatchingReceipt(
        sessionEpoch = source.sessionEpoch(),
        toggleRevision = source.toggleRevision(),
    )

    private fun snapshotLocked(
        before: List<MetaItem>,
        currentReceipt: TraktContinueWatchingReceipt,
    ) = TraktContinueWatchingRefresh(
        items = cached,
        changed = before != cached,
        receipt = currentReceipt,
        errorMessage = errorMessage,
    )

    private fun resetLocked(nextReceipt: TraktContinueWatchingReceipt?) {
        revision += 1
        receipt = nextReceipt
        lastSuccessAt = null
        cached = emptyList()
        errorMessage = null
    }

    private sealed interface RefreshPlan {
        data class Immediate(val refresh: TraktContinueWatchingRefresh) : RefreshPlan
        data class Fetch(
            val receipt: TraktContinueWatchingReceipt,
            val revision: Long,
            val before: List<MetaItem>,
        ) : RefreshPlan
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
    override fun toggleRevision(): Long = ScrobbleService.toggleChanges.value
    override fun isEnabled(): Boolean = sessionEpoch() != null

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
    val aliases: Set<String> = emptySet(),
)

/** Newest valid pause wins; exact type/id duplicates cannot produce duplicate cards. */
internal fun foldTraktContinueWatching(rows: List<JSONObject>): List<TraktContinueWatchingSeed> {
    return dedupeContinueWatchingSeeds(rows.mapNotNull(::traktSeed),
        aliases = { it.aliases.ifEmpty { setOf("${it.type.id}|${it.id}") } },
        comparator = compareByDescending { seed: TraktContinueWatchingSeed -> parseContinueWatchingActivity(seed.pausedAt) }
            .thenBy { it.id })
}

private fun traktSeed(row: JSONObject): TraktContinueWatchingSeed? {
    val progress = row.optDouble("progress", Double.NaN)
    if (!progress.isFinite() || progress <= 0.0 || progress >= 95.0) return null
    val pausedAt = row.optString("paused_at")
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
        aliases = listOfNotNull(imdb, tmdb?.let { if (isEpisode) "tmdb:tv:$it" else "tmdb:movie:$it" })
            .mapTo(mutableSetOf()) { "${type.id}|$it" },
    )
}

/** Reuses the signed TMDB edge. Episodes use the typed TV path and prefer their still over the show backdrop. */
internal object TraktPlaybackArtwork {
    suspend fun resolve(seed: TraktContinueWatchingSeed): MetaItem {
        val tmdb = seed.tmdbId ?: resolveTmdb(seed) ?: return traktContinueWatchingFallback(seed)
        val media = if (seed.type == MediaType.SERIES) "tv" else "movie"
        val detail = CatalogTmdbEdge.getJson("/$media/$tmdb")
        val episode = if (media == "tv" && seed.season != null && seed.episode != null) {
            CatalogTmdbEdge.getJson("/tv/$tmdb/season/${seed.season}/episode/${seed.episode}")
        } else null
        val poster = detail?.optStringOrNull("poster_path")?.let { "${CatalogTmdbEdge.IMAGE_BASE}/w342$it" }
        val backdrop = episode?.optStringOrNull("still_path") ?: detail?.optStringOrNull("backdrop_path")
        return traktContinueWatchingFallback(seed).copy(
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

}

/** Builds the remote read-only card before artwork enrichment; it deliberately has no local resume value. */
internal fun traktContinueWatchingFallback(seed: TraktContinueWatchingSeed) = MetaItem(
    id = seed.id, type = seed.type, name = seed.name, progress = (seed.progress / 100f).coerceIn(0f, 1f),
    continueWatchingActivityAtMillis = parseContinueWatchingActivity(seed.pausedAt),
    preferredEpisode = if (seed.type == MediaType.SERIES && seed.season != null && seed.episode != null) {
        PreferredEpisode(season = seed.season, episode = seed.episode)
    } else {
        null
    },
    caption = if (seed.type == MediaType.SERIES) {
        "S${seed.season} E${seed.episode}" + seed.episodeName?.let { " · $it" }.orEmpty()
    } else null,
)

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
