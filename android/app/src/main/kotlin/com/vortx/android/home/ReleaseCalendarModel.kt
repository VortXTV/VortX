package com.vortx.android.home

import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

internal const val UPCOMING_EPISODES_CATALOG_ID = "vortx.home.upcomingEpisodes"
internal const val UPCOMING_MOVIES_CATALOG_ID = "vortx.home.upcomingMovies"

internal data class ReleaseCalendarRefresh(
    val episodes: List<MetaItem>,
    val movies: List<MetaItem>,
    val changed: Boolean,
)

internal fun interface UpcomingMetaFetcher {
    suspend fun fetch(base: String, type: MediaType, id: String): JSONObject?
}

/** Builds the two 45-day release rails from profile-local library and watchlist seeds. */
internal class ReleaseCalendarModel(
    private val fetcher: UpcomingMetaFetcher = HttpUpcomingMetaFetcher,
) {
    private var signature: String? = null
    private var cachedEpisodes: List<MetaItem> = emptyList()
    private var cachedMovies: List<MetaItem> = emptyList()
    private val fetchSlots = Semaphore(MAX_CONCURRENT_FETCHES)

    suspend fun refresh(
        library: List<MetaItem>,
        watchlist: List<MetaItem>,
        metaBases: List<String>,
        reference: Instant = Instant.now(),
        onInvalidated: () -> Unit = {},
    ): ReleaseCalendarRefresh {
        val previousEpisodes = cachedEpisodes
        val previousMovies = cachedMovies
        val seeds = (library + watchlist)
            .asSequence()
            .filter { it.id.startsWith("tt") || it.id.startsWith("tmdb:") }
            .distinctBy { "${it.type.id}:${it.id}" }
            .toList()
        val series = seeds.filter { it.type == MediaType.SERIES }.take(MAX_TITLES)
        val movies = seeds.filter { it.type == MediaType.MOVIE }.take(MAX_TITLES)
        val bases = metaBases.map(String::trim).filter(String::isNotEmpty).distinct()
        if ((series.isEmpty() && movies.isEmpty()) || bases.isEmpty()) {
            return replace(emptyList(), emptyList(), null)
        }

        val nextSignature = buildString {
            append(reference.epochSecond / SECONDS_PER_DAY)
            append('|')
            append(series.joinToString(",") { it.id })
            append('|')
            append(movies.joinToString(",") { it.id })
            append('|')
            append(bases.joinToString(","))
        }
        if (nextSignature == signature) {
            return ReleaseCalendarRefresh(cachedEpisodes, cachedMovies, changed = false)
        }
        if (signature != null && signature != nextSignature) {
            cachedEpisodes = emptyList()
            cachedMovies = emptyList()
            onInvalidated()
        }

        val horizon = reference.plusSeconds(HORIZON_DAYS * SECONDS_PER_DAY)
        val (builtEpisodes, builtMovies) = coroutineScope {
            val episodeWork = series.map { seed ->
                async { fetchSlots.withPermit { upcomingEpisode(seed, bases, reference, horizon) } }
            }
            val movieWork = movies.map { seed ->
                async { fetchSlots.withPermit { upcomingMovie(seed, bases, reference, horizon) } }
            }
            episodeWork.awaitAll().filterNotNull().sortedBy(UpcomingItem::date).map(UpcomingItem::item) to
                movieWork.awaitAll().filterNotNull().sortedBy(UpcomingItem::date).map(UpcomingItem::item)
        }
        if (builtEpisodes.isEmpty() && builtMovies.isEmpty()) {
            return if (previousEpisodes.isNotEmpty() || previousMovies.isNotEmpty()) {
                // A fully empty fan-out after a populated build is indistinguishable from a transient
                // add-on/network miss. Restore the visible result and clear the signature so the next
                // refresh retries instead of blanking both rails.
                replace(previousEpisodes, previousMovies, null)
            } else {
                // An honest first empty is stable for the day and must not refetch on every incremental
                // Home-board emission.
                replace(emptyList(), emptyList(), nextSignature)
            }
        }
        return replace(builtEpisodes, builtMovies, nextSignature)
    }

    private suspend fun upcomingEpisode(
        seed: MetaItem,
        bases: List<String>,
        reference: Instant,
        horizon: Instant,
    ): UpcomingItem? {
        val meta = firstMeta(seed.id, MediaType.SERIES, bases) ?: return null
        val videos = meta.optJSONArray("videos") ?: return null
        var best: JSONObject? = null
        var bestDate: Instant? = null
        for (index in 0 until videos.length()) {
            val video = videos.optJSONObject(index) ?: continue
            val date = releaseInstant(video.optStringOrNull("released")) ?: continue
            if (date <= reference || date >= horizon || (bestDate != null && date >= bestDate)) continue
            best = video
            bestDate = date
        }
        val video = best ?: return null
        val date = bestDate ?: return null
        val episode = video.optIntOrNull("episode")
        val season = video.optIntOrNull("season")
        val episodeLabel = when {
            episode == null -> video.optStringOrNull("title") ?: "New episode"
            season != null -> "S${season}E$episode"
            else -> "E$episode"
        }
        val caption = "$episodeLabel · ${dateLabel(date)}"
        return UpcomingItem(
            item = MetaItem(
                id = seed.id,
                type = MediaType.SERIES,
                name = meta.optStringOrNull("name") ?: seed.name,
                poster = video.optStringOrNull("thumbnail")
                    ?: meta.optStringOrNull("poster")
                    ?: seed.poster,
                caption = caption,
            ),
            date = date,
        )
    }

    private suspend fun upcomingMovie(
        seed: MetaItem,
        bases: List<String>,
        reference: Instant,
        horizon: Instant,
    ): UpcomingItem? {
        val meta = firstMeta(seed.id, MediaType.MOVIE, bases) ?: return null
        val date = releaseInstant(meta.optStringOrNull("released"))
            ?: releaseInstant(meta.optStringOrNull("releaseInfo"))
            ?: return null
        if (date <= reference || date >= horizon) return null
        return UpcomingItem(
            item = MetaItem(
                id = seed.id,
                type = MediaType.MOVIE,
                name = meta.optStringOrNull("name") ?: seed.name,
                poster = meta.optStringOrNull("poster") ?: seed.poster,
                caption = dateLabel(date),
            ),
            date = date,
        )
    }

    private suspend fun firstMeta(id: String, type: MediaType, bases: List<String>): JSONObject? {
        for (base in bases) {
            val meta = fetcher.fetch(base, type, id)?.optJSONObject("meta")
            if (meta != null) return meta
        }
        return null
    }

    private fun replace(
        episodes: List<MetaItem>,
        movies: List<MetaItem>,
        nextSignature: String?,
    ): ReleaseCalendarRefresh {
        val changed = episodes != cachedEpisodes || movies != cachedMovies
        cachedEpisodes = episodes
        cachedMovies = movies
        signature = nextSignature
        return ReleaseCalendarRefresh(episodes, movies, changed)
    }

    private data class UpcomingItem(val item: MetaItem, val date: Instant)

    private companion object {
        const val HORIZON_DAYS = 45L
        const val MAX_TITLES = 60
        const val MAX_CONCURRENT_FETCHES = 6
        const val SECONDS_PER_DAY = 86_400L
    }
}

internal fun upcomingMetaBases(addons: List<InstalledAddon>): List<String> = addons.asSequence()
    .filter { it.providesMeta && !it.isDisabled }
    .mapNotNull { addon ->
        val url = addon.transportUrl.toHttpUrlOrNull() ?: return@mapNotNull null
        val path = url.encodedPath.trimEnd('/').removeSuffix("/manifest.json").trimEnd('/')
        url.newBuilder()
            .encodedPath(path.ifEmpty { "/" })
            .query(null)
            .fragment(null)
            .build()
            .toString()
            .trimEnd('/')
    }
    .distinct()
    .toList()

internal fun withReleaseCalendarRails(
    rows: List<com.vortx.android.model.Catalog>,
    episodes: List<MetaItem>,
    movies: List<MetaItem>,
): List<com.vortx.android.model.Catalog> {
    val base = rows.filterNot { it.id == UPCOMING_EPISODES_CATALOG_ID || it.id == UPCOMING_MOVIES_CATALOG_ID }
    if (episodes.isEmpty() && movies.isEmpty()) return base
    val anchor = base.indexOfLast {
        it.id.startsWith("vortx.home.importedLists:") ||
            it.id.startsWith("vortx.home.mediaServers:")
    }
        .takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == SIMKL_WATCHLIST_CATALOG_ID }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == TRAKT_WATCHLIST_CATALOG_ID }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == BECAUSE_YOU_WATCHED_CATALOG_ID }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == TOP_PICKS_CATALOG_ID }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "continue" }.takeIf { it >= 0 }
        ?: -1
    return base.toMutableList().apply {
        var insertion = anchor + 1
        if (episodes.isNotEmpty()) {
            add(insertion, com.vortx.android.model.Catalog(UPCOMING_EPISODES_CATALOG_ID, "Upcoming Episodes", episodes))
            insertion += 1
        }
        if (movies.isNotEmpty()) {
            add(insertion, com.vortx.android.model.Catalog(UPCOMING_MOVIES_CATALOG_ID, "Upcoming Movies", movies))
        }
    }
}

private object HttpUpcomingMetaFetcher : UpcomingMetaFetcher {
    private const val TIMEOUT_MS = 12_000L
    private const val MAX_META_BYTES = 8 * 1024 * 1024
    private val client = OkHttpClient.Builder()
        .connectTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .readTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .callTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .followRedirects(true)
        .build()

    override suspend fun fetch(base: String, type: MediaType, id: String): JSONObject? =
        suspendCancellableCoroutine { continuation ->
            val root = base.toHttpUrlOrNull()
            val url = root?.newBuilder()
                ?.addPathSegment("meta")
                ?.addPathSegment(type.id)
                ?.addPathSegment("$id.json")
                ?.build()
            if (url == null) {
                continuation.resume(null)
                return@suspendCancellableCoroutine
            }
            val call = client.newCall(Request.Builder().url(url).get().build())
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resume(null)
                }

                override fun onResponse(call: Call, response: Response) {
                    val parsed = response.use {
                        val body = it.body
                        if (!it.isSuccessful || body == null || body.contentLength() > MAX_META_BYTES) {
                            null
                        } else {
                            val bytes = body.source().readByteArray((MAX_META_BYTES + 1).toLong())
                            if (bytes.size > MAX_META_BYTES) null
                            else runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull()
                        }
                    }
                    if (continuation.isActive) continuation.resume(parsed)
                }
            })
        }
}

private fun releaseInstant(raw: String?): Instant? {
    val value = raw?.trim().takeUnless { it.isNullOrEmpty() } ?: return null
    return runCatching { OffsetDateTime.parse(value).toInstant() }
        .recoverCatching { Instant.parse(value) }
        .recoverCatching {
            require(value.length >= 10)
            LocalDate.parse(value.take(10)).atStartOfDay(ZoneId.systemDefault()).toInstant()
        }
        .getOrNull()
}

private fun dateLabel(date: Instant): String = DateTimeFormatter.ofPattern("MMM d", Locale.getDefault())
    .withZone(ZoneId.systemDefault())
    .format(date)

private fun JSONObject.optStringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).ifBlank { null }
}

private fun JSONObject.optIntOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return optInt(key)
}
