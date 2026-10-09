package com.vortx.android.home

import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.simklReadPath
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject

internal interface SimklContinueWatchingSource {
    fun sessionEpoch(): Long?
    suspend fun get(path: String, expectedEpoch: Long): Result<String>
}

private object SimklContinueWatchingApi : SimklContinueWatchingSource {
    override fun sessionEpoch() = SIMKLAuth.currentSessionEpoch
    override suspend fun get(path: String, expectedEpoch: Long): Result<String> = try {
        val response = SIMKLAuth.sessionBoundGet(path, expectedEpoch) ?: error("SIMKL session changed")
        check(response.status in 200..299) { "SIMKL read unavailable" }
        Result.success(response.body)
    } catch (cancelled: CancellationException) { throw cancelled }
    catch (error: Throwable) { Result.failure(error) }
}

internal data class SimklContinueWatchingRefresh(val items: List<MetaItem>, val sessionEpoch: Long?, val errorMessage: String? = null)

/** Activities are read before the pulls; all legs and their cursor commit together or retain the old snapshot. */
internal class SimklContinueWatchingModel(
    private val source: SimklContinueWatchingSource = SimklContinueWatchingApi,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val resolveArtwork: suspend (SimklContinueWatchingSeed) -> MetaItem = { seed ->
        simklContinueWatchingPresentation(seed, TraktPlaybackArtwork.resolve(seed.artworkSeed()))
    },
) {
    private val mutex = Mutex()
    private val lock = Any()
    private var revision = 0L
    private var epoch: Long? = null
    private var activities: JSONObject? = null
    private var library: Map<String, JSONObject> = emptyMap()
    private var playback: List<JSONObject> = emptyList()
    private var cached: List<MetaItem> = emptyList()
    private var lastAttempt: Long? = null
    private var errorMessage: String? = null

    suspend fun refresh(allowOwner: Boolean): SimklContinueWatchingRefresh = mutex.withLock {
        val plan = synchronized(lock) {
            val next = source.sessionEpoch()
            if (!allowOwner || next == null) { reset(null); return@withLock snapshot() }
            if (epoch != next) reset(next)
            val elapsed = lastAttempt?.let { nowMillis() - it }
            if (elapsed != null && elapsed in 0 until 300_000) return@withLock snapshot()
            lastAttempt = nowMillis()
            Plan(next, revision, activities, library, playback)
        }
        val result = try {
            val nextActivities = JSONObject(source.get("/sync/activities", plan.epoch).getOrThrow())
            require(nextActivities.has("all") && (nextActivities.isNull("all") || parseContinueWatchingActivity(nextActivities.optString("all")) != null)) {
                "SIMKL activity cursor unavailable" }
            val initial = plan.activities == null
            val libraryChanged = initial || bucketsChanged(plan.activities, nextActivities,
                listOf("watching", "plantowatch", "hold", "completed", "dropped", "notinteresting"))
            val removed = !initial && bucketsChanged(plan.activities, nextActivities, listOf("removed_from_list"))
            var nextLibrary = plan.library
            if (libraryChanged) {
                val params = linkedMapOf("next_watch_info" to "yes")
                plan.activities?.takeUnless { it.isNull("all") }?.optString("all")?.let { params["date_from"] = it }
                val delta = simklLibraryRows(JSONObject(source.get(simklReadPath("/sync/all-items", params), plan.epoch).getOrThrow()))
                nextLibrary = if (initial) delta else mergeSimklLibraryDelta(nextLibrary, delta)
            }
            if (removed) {
                val current = simklLibraryRows(JSONObject(source.get(simklReadPath("/sync/all-items",
                    mapOf("extended" to "simkl_ids_only")), plan.epoch).getOrThrow())).keys
                nextLibrary = nextLibrary.filterKeys(current::contains)
            }
            // Playback removals and plan-based expiry carry no tombstones. A throttled full playback pull
            // reconciles both, even when activities are unchanged; no date_from playback merge can do that.
            val nextPlayback = jsonObjects(JSONArray(source.get(simklReadPath("/sync/playback",
                mapOf("hide_watched" to "true", "limit" to "10000")), plan.epoch).getOrThrow()))
            require(nextPlayback.size < 10000) { "SIMKL playback snapshot may be incomplete" }
            val seeds = foldSimklContinueWatching(nextPlayback, nextLibrary.values.toList())
            val slots = Semaphore(6)
            val items = coroutineScope { seeds.map { seed -> async { slots.withPermit { resolveArtwork(seed) } } }.awaitAll() }
            Result.success(Accepted(nextActivities, nextLibrary, nextPlayback, items))
        } catch (cancelled: CancellationException) {
            synchronized(lock) { if (revision == plan.revision && epoch == plan.epoch) lastAttempt = null }
            throw cancelled
        }
        catch (error: Throwable) { Result.failure(error) }
        synchronized(lock) {
            if (revision != plan.revision || epoch != plan.epoch || source.sessionEpoch() != plan.epoch) {
                if (revision == plan.revision) reset(null)
                return@withLock snapshot()
            }
            result.onSuccess { accepted ->
                activities = accepted.activities; library = accepted.library; playback = accepted.playback
                cached = accepted.items; errorMessage = null
            }.onFailure { errorMessage = "Couldn't refresh SIMKL Continue Watching. Try again." }
            snapshot()
        }
    }

    fun clear() = synchronized(lock) { reset(null) }
    internal fun acceptedCursor(): String? = synchronized(lock) { activities?.takeUnless { it.isNull("all") }?.optString("all") }
    private fun snapshot() = SimklContinueWatchingRefresh(cached, epoch, errorMessage)
    private fun reset(next: Long?) {
        revision += 1; epoch = next; activities = null; library = emptyMap(); playback = emptyList()
        cached = emptyList(); lastAttempt = null; errorMessage = null
    }
    private data class Plan(val epoch: Long, val revision: Long, val activities: JSONObject?, val library: Map<String, JSONObject>, val playback: List<JSONObject>)
    private data class Accepted(val activities: JSONObject, val library: Map<String, JSONObject>, val playback: List<JSONObject>, val items: List<MetaItem>)
}

private fun bucketsChanged(before: JSONObject?, after: JSONObject, fields: List<String>): Boolean =
    listOf("tv_shows", "anime", "movies").any { type -> fields.any { field ->
        before?.optJSONObject(type)?.opt(field) != after.optJSONObject(type)?.opt(field)
    } }

internal fun mergeSimklLibraryDelta(base: Map<String, JSONObject>, delta: Map<String, JSONObject>): Map<String, JSONObject> {
    val changedAliases = delta.values.flatMap(::simklLibraryAliases).toSet()
    return base.filterValues { old -> simklLibraryAliases(old).none(changedAliases::contains) } + delta
}

private fun simklLibraryAliases(row: JSONObject): Set<String> {
    val media = row.optJSONObject("movie") ?: row.optJSONObject("show") ?: row.optJSONObject("anime") ?: return emptySet()
    val type = if (row.has("movie") || row.optString("anime_type") == "movie" || media.optString("anime_type") == "movie") "movie" else "series"
    val ids = media.optJSONObject("ids") ?: return emptySet()
    return listOf("imdb", "simkl", "tmdb", "tvdb", "mal", "anilist", "anidb").mapNotNull { key ->
        ids.opt(key)?.takeUnless { it == JSONObject.NULL }?.toString()?.takeIf(String::isNotBlank)?.let { "$type|$key:$it" }
    }.toSet()
}

/** Full all-items and delta payloads include terminal statuses so held/dropped/caught-up rows retire. */
internal fun simklLibraryRows(payload: JSONObject): Map<String, JSONObject> = buildMap {
    listOf("shows", "anime", "movies").forEach { type ->
        require(!payload.has(type) || payload.opt(type) is JSONArray) { "Invalid SIMKL library snapshot" }
        payload.optJSONArray(type)?.let(::jsonObjects)?.forEach { row ->
            val copy = JSONObject(row.toString()).put("vortxWireType", type)
            val media = row.optJSONObject(if (type == "movies") "movie" else "show") ?: row.optJSONObject("anime")
                ?: error("SIMKL title unavailable")
            val ids = media.optJSONObject("ids") ?: error("SIMKL title identity unavailable")
            val simkl = ids.opt("simkl")?.toString()?.takeIf { it.toLongOrNull()?.let { n -> n > 0 } == true }
                ?: error("SIMKL reconciliation identity unavailable")
            // Shows and anime share title aliases, but their reconciliation buckets remain distinct.
            put("$type|$simkl", copy)
        }
    }
}

internal data class SimklContinueWatchingSeed(
    val id: String, val type: MediaType, val title: String, val aliases: Set<String>,
    val activityAtMillis: Long?, val progress: Float?, val preferredEpisode: PreferredEpisode?,
    val episodeName: String?, val imdb: String?, val tmdb: Int?,
) {
    fun unavailableMessage(): String? = when {
        imdb == null && tmdb == null -> "Playback unavailable: SIMKL has no supported title identity."
        type == MediaType.SERIES && preferredEpisode == null -> "Playback unavailable: SIMKL has no exact episode identity."
        else -> null
    }
    fun artworkSeed() = TraktContinueWatchingSeed(id, type, title, progress ?: 0f, "", tmdb, imdb,
        preferredEpisode?.season, preferredEpisode?.episode, episodeName)
}

internal fun simklContinueWatchingPresentation(seed: SimklContinueWatchingSeed, artwork: MetaItem): MetaItem = artwork.copy(
    id = seed.id, type = seed.type, name = seed.title, progress = seed.progress?.div(100f),
    preferredEpisode = seed.preferredEpisode, continueWatchingActivityAtMillis = seed.activityAtMillis, resumeSeconds = null,
    continueWatchingUnavailableMessage = seed.unavailableMessage(),
    caption = seed.unavailableMessage() ?: seed.preferredEpisode?.let { "S${it.season} E${it.episode}" + seed.episodeName?.let { name -> " · $name" }.orEmpty() },
)

internal fun foldSimklContinueWatching(playback: List<JSONObject>, library: List<JSONObject>): List<SimklContinueWatchingSeed> {
    val paused = playback.mapNotNull { simklSeed(it, true) }
    val next = library.mapNotNull { simklSeed(it, false) }
    return dedupeContinueWatchingSeeds(paused + next, SimklContinueWatchingSeed::aliases,
        compareByDescending<SimklContinueWatchingSeed> { it.progress != null }
            .thenByDescending { it.activityAtMillis }.thenBy { it.id })
        .sortedWith(compareByDescending<SimklContinueWatchingSeed> { it.activityAtMillis }.thenBy { it.id })
}

private fun simklSeed(row: JSONObject, paused: Boolean): SimklContinueWatchingSeed? {
    val movie = row.optJSONObject("movie")
    val media = movie ?: row.optJSONObject("show") ?: row.optJSONObject("anime") ?: return null
    val type = if (movie != null || row.optString("anime_type") == "movie" || media.optString("anime_type") == "movie") MediaType.MOVIE else MediaType.SERIES
    val anime = row.has("anime") || row.has("anime_type") || media.has("anime_type") || row.optString("vortxWireType") == "anime"
    val ids = media.optJSONObject("ids") ?: return null
    val imdb = ids.optString("imdb").takeIf { it.startsWith("tt") && it.drop(2).length >= 6 && it.drop(2).all(Char::isDigit) }
    val tmdb = ids.opt("tmdb")?.toString()?.toIntOrNull()?.takeIf { it > 0 }
    // A genuine SIMKL-only title is still in progress. Keep its source namespace, never invent an engine id.
    val id = imdb ?: tmdb?.let { if (type == MediaType.MOVIE) "tmdb:movie:$it" else "tmdb:tv:$it" }
        ?: ids.opt("simkl")?.toString()?.toLongOrNull()?.takeIf { it > 0 }?.let { "simkl:${type.id}:$it" } ?: return null
    val episode: JSONObject?
    val progress: Float?
    val at: Long?
    if (paused) {
        val value = row.optDouble("progress", Double.NaN)
        if (!value.isFinite() || value <= 0 || value >= 95) return null
        progress = value.toFloat(); episode = if (type == MediaType.SERIES) row.optJSONObject("episode") else null
        at = parseContinueWatchingActivity(row.optString("paused_at")) ?: parseContinueWatchingActivity(row.optString("watched_at"))
    } else {
        if (type == MediaType.MOVIE || row.optString("status") != "watching") return null
        if (!row.has("next_to_watch") || row.isNull("next_to_watch")) return null
        val marker = row.optString("next_to_watch")
        val parts = Regex("^S([0-9]+)E([0-9]+)$", RegexOption.IGNORE_CASE).matchEntire(marker)
        val info = row.optJSONObject("next_to_watch_info")
        val legacy = row.optJSONObject("next_to_watch")
        episode = if (parts != null) {
            val season = parts.groupValues[1].toIntOrNull()?.takeIf { it >= 0 }
            val number = parts.groupValues[2].toIntOrNull()?.takeIf { it > 0 }
            if (season == null || number == null ||
                info?.has("season") == true && simklEpisodeCoordinate(info, "season", 0) != season ||
                info?.has("episode") == true && simklEpisodeCoordinate(info, "episode", 1) != number) null
            else if (anime) info?.takeIf { it.has("tvdb_season") && it.has("tvdb_number") }
            else JSONObject().put("season", season).put("number", number).put("title", info?.optString("title"))
        } else if (anime) info else legacy
        progress = null
        at = parseContinueWatchingActivity(row.optString("last_watched_at"))
            ?: parseContinueWatchingActivity(row.optJSONObject("last_watched")?.optString("watched_at"))
    }
    val hint = if (type == MediaType.SERIES) {
        val mapped = episode?.has("tvdb_season") == true || episode?.has("tvdb_number") == true
        val season = if (mapped) simklEpisodeCoordinate(episode, "tvdb_season", 0)
            else if (!anime) simklEpisodeCoordinate(episode, "season", 0) else null
        val number = if (mapped) simklEpisodeCoordinate(episode, "tvdb_number", 1)
            else if (!anime) simklEpisodeCoordinate(episode, if (episode?.has("number") == true) "number" else "episode", 1) else null
        if (season != null && number != null) PreferredEpisode(season, number) else null
    } else null
    val aliases = mutableSetOf("${type.id}|$id")
    listOf("imdb", "simkl", "tvdb", "mal", "anilist", "anidb").forEach { key ->
        ids.opt(key)?.takeUnless { it == JSONObject.NULL }?.toString()?.takeIf(String::isNotBlank)
            ?.let { aliases += "${type.id}|$key:$it" }
    }
    tmdb?.let { aliases += "${type.id}|tmdb:$it" }
    return SimklContinueWatchingSeed(id, type, media.optString("title").ifBlank { id }, aliases, at, progress, hint,
        episode?.optString("title")?.takeIf(String::isNotBlank), imdb, tmdb)
}

/** JSONObject.optInt silently rounds fractions and accepts strings. Exact routes accept neither. */
private fun simklEpisodeCoordinate(episode: JSONObject?, key: String, minimum: Int): Int? {
    val number = (episode?.opt(key) as? Number)?.toDouble() ?: return null
    return number.takeIf { it.isFinite() && it >= minimum && it <= Int.MAX_VALUE && it == kotlin.math.floor(it) }?.toInt()
}

private fun jsonObjects(array: JSONArray): List<JSONObject> = (0 until array.length()).map { array.getJSONObject(it) }
