package com.vortx.android.downloads

import com.vortx.android.catalog.CatalogTmdbEdge
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.sources.CanonicalContentIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

/** Device-local evidence from an exact canonical TV season pair. No account or playback credential. */
data class DownloadedSeasonBoundary internal constructor(
    val contentId: String,
    val originVideoId: String,
    val season: Int,
    val finalEpisode: Int,
    val nextVideoId: String,
    val tmdbId: Int,
    val imdbId: String?,
    val finalTmdbEpisodeId: Int,
    val firstTmdbEpisodeId: Int,
) {
    init {
        require(season in 1 until Int.MAX_VALUE && finalEpisode > 0 && tmdbId > 0)
        require(imdbId == null || CanonicalContentIdentity.imdb(imdbId) == imdbId)
        require(contentId == imdbId || canonicalTmdbSeries(contentId) == tmdbId)
        require(canonicalVideo(originVideoId, imdbId, tmdbId, season, finalEpisode))
        require(canonicalVideo(nextVideoId, imdbId, tmdbId, season + 1, 1))
        require(finalTmdbEpisodeId > 0 && firstTmdbEpisodeId > 0 && finalTmdbEpisodeId != firstTmdbEpisodeId)
    }

    internal fun matchesOrigin(record: DownloadRecord): Boolean =
        record.type == "series" && record.contentId == contentId && record.videoId == originVideoId &&
            record.season == season && record.episode == finalEpisode

    internal fun matchesNext(record: DownloadRecord): Boolean =
        record.state == DownloadState.COMPLETED && record.type == "series" && record.contentId == contentId &&
            record.videoId == nextVideoId && record.season == season + 1 && record.episode == 1

    /** Exact indexed episode evidence can permanently disprove a previously saved finale. */
    internal fun isDisprovedByLaterEpisode(record: DownloadRecord): Boolean {
        val number = record.episode ?: return false
        return record.type == "series" && record.contentId == contentId && record.season == season &&
            number > finalEpisode && canonicalVideo(record.videoId, imdbId, tmdbId, season, number)
    }

    internal fun contradicts(record: DownloadRecord): Boolean =
        record.type == "series" && record.contentId == contentId && (
            (record.season == season && (record.episode ?: 0) > finalEpisode) ||
                (record.season == season + 1 && record.episode == 1 && record.videoId != nextVideoId)
            )

    internal fun toJson(): JSONObject = JSONObject().put("version", 1).put("contentId", contentId)
        .put("originVideoId", originVideoId).put("season", season).put("finalEpisode", finalEpisode)
        .put("nextVideoId", nextVideoId).put("tmdbId", tmdbId).put("imdbId", imdbId ?: JSONObject.NULL)
        .put("finalTmdbEpisodeId", finalTmdbEpisodeId).put("firstTmdbEpisodeId", firstTmdbEpisodeId)

    companion object {
        internal fun read(json: JSONObject?): DownloadedSeasonBoundary? = runCatching {
            if (json == null || json.positiveInt("version") != 1) return null
            val imdb = json.get("imdbId")
            DownloadedSeasonBoundary(json.get("contentId") as String, json.get("originVideoId") as String,
                requireNotNull(json.positiveInt("season")), requireNotNull(json.positiveInt("finalEpisode")),
                json.get("nextVideoId") as String, requireNotNull(json.positiveInt("tmdbId")),
                if (imdb == JSONObject.NULL) null else imdb as String,
                requireNotNull(json.positiveInt("finalTmdbEpisodeId")),
                requireNotNull(json.positiveInt("firstTmdbEpisodeId")))
        }.getOrNull()
    }
}

/** A generated download ID and its immutable placement. Ordinary transfer-state changes retain both. */
internal data class DownloadedSeasonFile(val id: String, val addedAt: Long, val filename: String) {
    constructor(record: DownloadRecord) : this(record.id, record.addedAt, record.localFilename)

    fun matches(record: DownloadRecord): Boolean =
        id == record.id && addedAt == record.addedAt && filename == record.localFilename
}

/** Same original boundary and physical successor throughout the offer/countdown and decoder admission. */
internal data class DownloadedRollover(
    val origin: DownloadedSeasonFile,
    val successor: DownloadedSeasonFile,
    val boundary: DownloadedSeasonBoundary,
) {
    fun isCurrent(records: List<DownloadRecord>): Boolean =
        records.none(boundary::contradicts) &&
            // The exact ended file was proved before the offer. Normal watched reclamation can now
            // remove it on decoder release, but a surviving predecessor may not replace its proof.
            (records.firstOrNull { it.id == origin.id }?.let {
                origin.matches(it) && boundary.matchesOrigin(it) &&
                    it.seasonBoundary == boundary && it.state == DownloadState.COMPLETED
            } != false) &&
            records.any { successor.matches(it) && boundary.matchesNext(it) }
}

/** Captures the original route refresh independently from the account/profile playback epoch. */
internal class DownloadedSeasonBoundaryRefreshFence {
    class Request internal constructor()
    private val active = AtomicReference<Request?>()

    fun begin(): Request = Request().also(active::set)
    fun invalidate() { active.set(null) }
    fun isCurrent(request: Request): Boolean = active.get() === request
}

private val tmdbSeriesId = Regex("tmdb:(?:tv:)?[1-9][0-9]{0,9}")
private const val SEASON_RESPONSE_BYTES = 2 * 1024 * 1024
private val refreshMutex = Mutex()

private fun canonicalTmdbSeries(id: String): Int? =
    id.takeIf(tmdbSeriesId::matches)?.substringAfterLast(':')?.toIntOrNull()

private fun canonicalVideo(id: String, imdb: String?, tmdb: Int, season: Int, episode: Int): Boolean =
    id == "tmdb:$tmdb:$season:$episode" || id == "tmdb:tv:$tmdb:$season:$episode" ||
        id == CanonicalContentIdentity.imdb(imdb, season, episode)

private fun DownloadRecord.isCanonicalEpisodeCandidate(): Boolean {
    val season = season?.takeIf { it > 0 } ?: return false
    val episode = episode?.takeIf { it > 0 } ?: return false
    val title = videoId.removeSuffix(":$season:$episode")
    return title != videoId && (CanonicalContentIdentity.imdb(title) != null || canonicalTmdbSeries(title) != null)
}

private fun JSONObject.exactInt(name: String): Int? = when (val value = opt(name)) {
    is Int -> value
    is Long -> value.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()
    else -> null
}

private fun JSONObject.positiveInt(name: String): Int? = exactInt(name)?.takeIf { it > 0 }

private data class TmdbSeason(val number: Int, val id: Int, val count: Int)

/** Only typed counts and unique descriptors from the exact series can authorize a boundary. */
private fun tmdbSeasons(show: JSONObject): Map<Int, TmdbSeason>? {
    val seasons = show.optJSONArray("seasons") ?: return null
    val numbers = HashMap<Int, TmdbSeason>()
    val ids = HashSet<Int>()
    for (index in 0 until seasons.length()) {
        val row = seasons.optJSONObject(index) ?: return null
        val number = row.exactInt("season_number")?.takeIf { it >= 0 } ?: return null
        val id = row.positiveInt("id") ?: return null
        val count = row.exactInt("episode_count")?.takeIf { it >= 0 } ?: return null
        if (!ids.add(id) || numbers.put(number, TmdbSeason(number, id, count)) != null) return null
    }
    return numbers
}

private fun completeSeasonEpisodeIds(tmdbId: Int, descriptor: TmdbSeason, season: JSONObject): List<Int>? {
    if (season.positiveInt("id") != descriptor.id || season.exactInt("season_number") != descriptor.number ||
        (season.has("show_id") && season.positiveInt("show_id") != tmdbId)
    ) return null
    val rows = season.optJSONArray("episodes") ?: return null
    if (descriptor.count <= 0 || rows.length() != descriptor.count) return null
    val episodeIds = IntArray(descriptor.count)
    val ids = HashSet<Int>()
    for (index in 0 until rows.length()) {
        val row = rows.optJSONObject(index) ?: return null
        val number = row.positiveInt("episode_number")?.takeIf { it <= descriptor.count } ?: return null
        val id = row.positiveInt("id") ?: return null
        if (row.exactInt("season_number") != descriptor.number || row.positiveInt("show_id") != tmdbId ||
            !ids.add(id) || episodeIds[number - 1] != 0
        ) return null
        episodeIds[number - 1] = id
    }
    return episodeIds.toList()
}

/** Bounded local admission precedes any public metadata request. Production callers keep the original UI owner. */
internal suspend fun refreshDownloadedSeasonBoundaries(
    contentIds: Set<String>,
    owner: PlaybackOwnerToken,
    routeGenerationCurrent: () -> Boolean,
    routeCurrentOnMain: () -> Boolean,
    startingSeason: Int? = null,
    metadataRequestAllowed: () -> Boolean = { true },
) = withContext(Dispatchers.IO) {
    val job = currentCoroutineContext()
    // Inside the index lock the route check is scalar only. A full CW admission can enter native.
    fun currentGeneration() = job.isActive && PlaybackOwnerEpoch.isCurrent(owner) && routeGenerationCurrent()
    suspend fun current(): Boolean {
        job.ensureActive()
        return currentGeneration() && withContext(Dispatchers.Main.immediate) {
            currentGeneration() && routeCurrentOnMain()
        }
    }
    suspend fun get(path: String): JSONObject? {
        if (!current() || !metadataRequestAllowed()) return null
        val response = CatalogTmdbEdge.getJson(path, maxBodyBytes = SEASON_RESPONSE_BYTES)
        return response.takeIf { current() }
    }
    // Two routes can target the same record. Serialize observations and snapshot after
    // admission so a later contradiction can see and retire a receipt written by the first.
    refreshMutex.withLock {
        for (contentId in contentIds) {
            if (!current()) return@withLock
            val rows = DownloadStore.records.value.filter {
                it.type == "series" && it.contentId == contentId && it.state != DownloadState.FAILED
            }
            val bySeason = rows.groupBy { it.season }
            val origins = rows.filter {
                val season = it.season ?: return@filter false
                season in 1 until Int.MAX_VALUE && (startingSeason == null || season >= startingSeason) &&
                    it.isCanonicalEpisodeCandidate() &&
                    bySeason[season + 1].orEmpty().any { candidate ->
                        candidate.episode == 1 && candidate.isCanonicalEpisodeCandidate()
                    }
            }
            if (origins.isEmpty()) continue
            // A direct binge can reach the current season finale before later season requests finish.
            val orderedOrigins = if (startingSeason == null) origins else origins.sortedBy { it.season }
            resolveDownloadedSeasonBoundaries(contentId, orderedOrigins, bySeason, ::get) { origin, boundary ->
                if (current()) DownloadManager.rememberSeasonBoundary(origin, boundary, ::currentGeneration)
            }
        }
    }
}

/** A null transport result preserves prior evidence. Typed contradictory metadata revokes it. */
internal suspend fun resolveDownloadedSeasonBoundaries(
    contentId: String,
    origins: List<DownloadRecord>,
    rowsBySeason: Map<Int?, List<DownloadRecord>>,
    get: suspend (String) -> JSONObject?,
    remember: suspend (DownloadRecord, DownloadedSeasonBoundary?) -> Unit,
) {
    suspend fun revoke(origin: DownloadRecord): DownloadRecord {
        if (origin.seasonBoundary == null) return origin
        remember(origin, null)
        return origin.copy(seasonBoundary = null)
    }
    val imdb = CanonicalContentIdentity.imdb(contentId)
    val tmdb = when {
        imdb != null -> {
            val hits = get("/find/$imdb?external_source=imdb_id")?.optJSONArray("tv_results") ?: return
            if (hits.length() != 1) {
                for (origin in origins) revoke(origin)
                return
            }
            hits.optJSONObject(0)?.positiveInt("id")
        }
        else -> canonicalTmdbSeries(contentId)
    } ?: return
    // The exact IMDb lookup can contradict a previously recorded TMDB ID on its own.
    val mappedOrigins = mutableListOf<DownloadRecord>()
    for (origin in origins) {
        val previousId = origin.seasonBoundary?.tmdbId
        mappedOrigins += if (previousId != null && previousId != tmdb) revoke(origin) else origin
    }
    suspend fun revokeMapped() {
        for (origin in mappedOrigins) revoke(origin)
    }
    val show = get("/tv/$tmdb?append_to_response=external_ids") ?: return
    if (show.positiveInt("id") != tmdb) { revokeMapped(); return }
    val external = show.optJSONObject("external_ids") ?: return
    if (!external.has("imdb_id")) return
    val rawImdb = external.opt("imdb_id")
    val confirmedImdb = CanonicalContentIdentity.imdb(rawImdb as? String)
    if ((imdb != null && confirmedImdb != imdb) ||
        (rawImdb != null && rawImdb != JSONObject.NULL && confirmedImdb == null)
    ) { revokeMapped(); return }
    val descriptors = tmdbSeasons(show) ?: run { revokeMapped(); return }
    val seasons = HashMap<Int, JSONObject?>()
    suspend fun season(number: Int): JSONObject? {
        if (!seasons.containsKey(number)) seasons[number] = get("/tv/$tmdb/season/$number")
        return seasons[number]
    }
    for (mapped in mappedOrigins) {
        var origin = mapped
        val prior = origin.seasonBoundary
        if (prior != null && prior.imdbId != confirmedImdb) origin = revoke(origin)
        val number = origin.season?.takeIf { it in 1 until Int.MAX_VALUE } ?: continue
        val episode = origin.episode?.takeIf { it > 0 } ?: continue
        if (origin.type != "series" || origin.contentId != contentId) continue
        val from = descriptors[number]
        val next = descriptors[number + 1]
        if (from == null || next == null || from.count != episode || next.count <= 0) {
            revoke(origin)
            continue
        }
        if (!canonicalVideo(origin.videoId, confirmedImdb, tmdb, number, episode)) continue
        val localNext = rowsBySeason[number + 1].orEmpty().filter { it.episode == 1 }.map { it.videoId }.distinct()
            .singleOrNull()?.takeIf { canonicalVideo(it, confirmedImdb, tmdb, number + 1, 1) }
        if (localNext == null && origin.seasonBoundary == null) continue

        val fromSeason = season(number)
        val fromIds = fromSeason?.let { completeSeasonEpisodeIds(tmdb, from, it) }
        if (fromSeason != null && fromIds == null) {
            revoke(origin)
            continue
        }
        val finalId = fromIds?.last()
        val previousFinal = origin.seasonBoundary?.finalTmdbEpisodeId
        if (finalId != null && previousFinal != null && previousFinal != finalId) origin = revoke(origin)
        // An unavailable predecessor cannot establish a new boundary. A retained one can still
        // be contradicted by the other season, including a shared response already in the cache.
        if (finalId == null && origin.seasonBoundary == null) continue

        val nextSeason = season(number + 1) ?: continue
        val nextIds = completeSeasonEpisodeIds(tmdb, next, nextSeason)
        if (nextIds == null || fromIds?.any(nextIds.toSet()::contains) == true) {
            revoke(origin)
            continue
        }
        val firstId = nextIds.first()
        val previousFirst = origin.seasonBoundary?.firstTmdbEpisodeId
        if (previousFirst != null && previousFirst != firstId) origin = revoke(origin)
        if (localNext == null || finalId == null) continue

        val evidence = DownloadedSeasonBoundary(contentId, origin.videoId, number, episode, localNext, tmdb,
            confirmedImdb, finalId, firstId)
        if (evidence != origin.seasonBoundary) remember(origin, evidence)
    }
}
