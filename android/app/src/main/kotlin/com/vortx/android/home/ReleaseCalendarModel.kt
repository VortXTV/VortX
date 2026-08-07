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
import okhttp3.ResponseBody
import okio.Buffer
import org.json.JSONObject
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

internal const val UPCOMING_EPISODES_CATALOG_ID = "vortx.home.upcomingEpisodes"
internal const val UPCOMING_MOVIES_CATALOG_ID = "vortx.home.upcomingMovies"

internal data class ReleaseCalendarOwner(
    val profileId: String,
    val generation: Long,
)

internal enum class ReleaseCalendarRailOutcome {
    UNCHANGED,
    UPDATED,
    INVALIDATED,
    RETAINED_AFTER_TRANSIENT_FAILURE,
    PARTIAL_AFTER_TRANSIENT_FAILURE,
    STALE_OWNER_IGNORED,
}

internal data class ReleaseCalendarRefresh(
    val episodes: List<MetaItem>,
    val movies: List<MetaItem>,
    val episodesChanged: Boolean,
    val moviesChanged: Boolean,
    val episodeOutcome: ReleaseCalendarRailOutcome,
    val movieOutcome: ReleaseCalendarRailOutcome,
) {
    val changed: Boolean get() = episodesChanged || moviesChanged
}

internal sealed interface UpcomingMetaResponse {
    data class Success(val payload: JSONObject?) : UpcomingMetaResponse
    object TransientFailure : UpcomingMetaResponse
}

internal fun interface UpcomingMetaFetcher {
    suspend fun fetch(base: String, type: MediaType, id: String): UpcomingMetaResponse
}

/** Builds the two 45-day release rails from profile-local library and watchlist seeds. */
internal class ReleaseCalendarModel(
    private val fetcher: UpcomingMetaFetcher = HttpUpcomingMetaFetcher,
) {
    private var activeOwner: ReleaseCalendarOwner? = null
    private val episodeState = RailState()
    private val movieState = RailState()
    private val fetchSlots = Semaphore(MAX_CONCURRENT_FETCHES)

    /**
     * Move the model to [owner] before any repository reads begin. A monotonically newer generation clears
     * both rails synchronously, so a failed profile-B refresh can never expose or restore profile-A data.
     * A late refresh from an older generation is rejected instead of moving ownership backwards.
     */
    fun activate(owner: ReleaseCalendarOwner): ReleaseCalendarRefresh {
        val current = activeOwner
        if (current == owner) return snapshot()
        if (current != null && owner.generation <= current.generation) {
            return snapshot(
                episodeOutcome = ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED,
                movieOutcome = ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED,
            )
        }
        activeOwner = owner
        val episodesChanged = episodeState.items.isNotEmpty()
        val moviesChanged = movieState.items.isNotEmpty()
        episodeState.clear()
        movieState.clear()
        return snapshot(
            episodesChanged = episodesChanged,
            moviesChanged = moviesChanged,
            episodeOutcome = ReleaseCalendarRailOutcome.INVALIDATED,
            movieOutcome = ReleaseCalendarRailOutcome.INVALIDATED,
        )
    }

    suspend fun refresh(
        owner: ReleaseCalendarOwner,
        library: List<MetaItem>,
        watchlist: List<MetaItem>,
        metaBases: List<String>,
        reference: Instant = Instant.now(),
        onInvalidated: (ReleaseCalendarRefresh) -> Unit = {},
    ): ReleaseCalendarRefresh {
        val activated = activate(owner)
        if (activated.episodeOutcome == ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED) return activated
        if (activated.changed) onInvalidated(activated)

        val seeds = (library + watchlist)
            .asSequence()
            .filter { it.id.startsWith("tt") || it.id.startsWith("tmdb:") }
            .distinctBy { "${it.type.id}:${it.id}" }
            .toList()
        val series = seeds.filter { it.type == MediaType.SERIES }.take(MAX_TITLES)
        val movies = seeds.filter { it.type == MediaType.MOVIE }.take(MAX_TITLES)
        val bases = metaBases.map(String::trim).filter(String::isNotEmpty).distinct()

        val episodeOwnerSeed = OwnerSeed(owner, series.joinToString(",") { it.id })
        val movieOwnerSeed = OwnerSeed(owner, movies.joinToString(",") { it.id })
        val episodeInvalidated = episodeState.prepare(episodeOwnerSeed)
        val movieInvalidated = movieState.prepare(movieOwnerSeed)
        if (episodeInvalidated || movieInvalidated) {
            onInvalidated(
                snapshot(
                    episodesChanged = episodeInvalidated,
                    moviesChanged = movieInvalidated,
                    episodeOutcome = if (episodeInvalidated) {
                        ReleaseCalendarRailOutcome.INVALIDATED
                    } else {
                        ReleaseCalendarRailOutcome.UNCHANGED
                    },
                    movieOutcome = if (movieInvalidated) {
                        ReleaseCalendarRailOutcome.INVALIDATED
                    } else {
                        ReleaseCalendarRailOutcome.UNCHANGED
                    },
                ),
            )
        }

        val dayAndBases = buildString {
            append(reference.epochSecond / SECONDS_PER_DAY)
            append('|')
            append(bases.joinToString(","))
        }
        val episodeSignature = "${episodeOwnerSeed.seedIds}|$dayAndBases"
        val movieSignature = "${movieOwnerSeed.seedIds}|$dayAndBases"
        val fetchEpisodes = episodeState.completedSignature != episodeSignature
        val fetchMovies = movieState.completedSignature != movieSignature
        if (!fetchEpisodes && !fetchMovies) return snapshot()

        val horizon = reference.plusSeconds(HORIZON_DAYS * SECONDS_PER_DAY)
        val (builtEpisodes, builtMovies) = coroutineScope {
            val episodeWork = if (fetchEpisodes) async {
                buildRail(series) { seed -> upcomingEpisode(seed, bases, reference, horizon) }
            } else {
                null
            }
            val movieWork = if (fetchMovies) async {
                buildRail(movies) { seed -> upcomingMovie(seed, bases, reference, horizon) }
            } else {
                null
            }
            episodeWork?.await() to movieWork?.await()
        }

        // Another Home refresh can supersede this one while the add-on requests are in flight. Both the
        // monotonic owner and the per-rail seed key must still match before either result may publish.
        if (activeOwner != owner || episodeState.ownerSeed != episodeOwnerSeed || movieState.ownerSeed != movieOwnerSeed) {
            return snapshot(
                episodeOutcome = ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED,
                movieOutcome = ReleaseCalendarRailOutcome.STALE_OWNER_IGNORED,
            )
        }

        val episodeResult = builtEpisodes?.let { episodeState.applyBuild(episodeSignature, it) }
        val movieResult = builtMovies?.let { movieState.applyBuild(movieSignature, it) }
        return snapshot(
            episodesChanged = episodeResult?.changed == true,
            moviesChanged = movieResult?.changed == true,
            episodeOutcome = episodeResult?.outcome ?: ReleaseCalendarRailOutcome.UNCHANGED,
            movieOutcome = movieResult?.outcome ?: ReleaseCalendarRailOutcome.UNCHANGED,
        )
    }

    private suspend fun buildRail(
        seeds: List<MetaItem>,
        build: suspend (MetaItem) -> ItemLookup,
    ): RailBuild {
        if (seeds.isEmpty()) return RailBuild(emptyList(), transientFailure = false)
        val outcomes = coroutineScope {
            seeds.map { seed -> async { fetchSlots.withPermit { build(seed) } } }.awaitAll()
        }
        return RailBuild(
            items = outcomes.mapNotNull { (it as? ItemLookup.Found)?.upcoming }
                .sortedBy(UpcomingItem::date)
                .map(UpcomingItem::item),
            transientFailure = outcomes.any { it === ItemLookup.TransientFailure },
        )
    }

    private suspend fun upcomingEpisode(
        seed: MetaItem,
        bases: List<String>,
        reference: Instant,
        horizon: Instant,
    ): ItemLookup {
        val meta = when (val lookup = firstMeta(seed.id, MediaType.SERIES, bases)) {
            is MetaLookup.Found -> lookup.meta
            MetaLookup.Missing -> return ItemLookup.Found(null)
            MetaLookup.TransientFailure -> return ItemLookup.TransientFailure
        }
        val videos = meta.optJSONArray("videos") ?: return ItemLookup.Found(null)
        var best: JSONObject? = null
        var bestDate: Instant? = null
        for (index in 0 until videos.length()) {
            val video = videos.optJSONObject(index) ?: continue
            val date = releaseInstant(video.optStringOrNull("released")) ?: continue
            if (date <= reference || date >= horizon || (bestDate != null && date >= bestDate)) continue
            best = video
            bestDate = date
        }
        val video = best ?: return ItemLookup.Found(null)
        val date = bestDate ?: return ItemLookup.Found(null)
        val episode = video.optIntOrNull("episode")
        val season = video.optIntOrNull("season")
        val episodeLabel = when {
            episode == null -> video.optStringOrNull("title") ?: "New episode"
            season != null -> "S${season}E$episode"
            else -> "E$episode"
        }
        val caption = "$episodeLabel · ${dateLabel(date)}"
        return ItemLookup.Found(
            UpcomingItem(
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
            ),
        )
    }

    private suspend fun upcomingMovie(
        seed: MetaItem,
        bases: List<String>,
        reference: Instant,
        horizon: Instant,
    ): ItemLookup {
        val meta = when (val lookup = firstMeta(seed.id, MediaType.MOVIE, bases)) {
            is MetaLookup.Found -> lookup.meta
            MetaLookup.Missing -> return ItemLookup.Found(null)
            MetaLookup.TransientFailure -> return ItemLookup.TransientFailure
        }
        val date = releaseInstant(meta.optStringOrNull("released"))
            ?: releaseInstant(meta.optStringOrNull("releaseInfo"))
            ?: return ItemLookup.Found(null)
        if (date <= reference || date >= horizon) return ItemLookup.Found(null)
        return ItemLookup.Found(
            UpcomingItem(
                item = MetaItem(
                    id = seed.id,
                    type = MediaType.MOVIE,
                    name = meta.optStringOrNull("name") ?: seed.name,
                    poster = meta.optStringOrNull("poster") ?: seed.poster,
                    caption = dateLabel(date),
                ),
                date = date,
            ),
        )
    }

    private suspend fun firstMeta(id: String, type: MediaType, bases: List<String>): MetaLookup {
        var sawTransientFailure = false
        for (base in bases) {
            val response = try {
                fetcher.fetch(base, type, id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                UpcomingMetaResponse.TransientFailure
            }
            when (response) {
                is UpcomingMetaResponse.Success -> {
                    val meta = response.payload?.optJSONObject("meta")
                    if (meta != null) return MetaLookup.Found(meta)
                }
                UpcomingMetaResponse.TransientFailure -> sawTransientFailure = true
            }
        }
        return if (sawTransientFailure) MetaLookup.TransientFailure else MetaLookup.Missing
    }

    private fun snapshot(
        episodesChanged: Boolean = false,
        moviesChanged: Boolean = false,
        episodeOutcome: ReleaseCalendarRailOutcome = ReleaseCalendarRailOutcome.UNCHANGED,
        movieOutcome: ReleaseCalendarRailOutcome = ReleaseCalendarRailOutcome.UNCHANGED,
    ) = ReleaseCalendarRefresh(
        episodes = episodeState.items,
        movies = movieState.items,
        episodesChanged = episodesChanged,
        moviesChanged = moviesChanged,
        episodeOutcome = episodeOutcome,
        movieOutcome = movieOutcome,
    )

    private data class OwnerSeed(val owner: ReleaseCalendarOwner, val seedIds: String)

    private class RailState {
        var ownerSeed: OwnerSeed? = null
        var completedSignature: String? = null
        var items: List<MetaItem> = emptyList()

        fun clear() {
            ownerSeed = null
            completedSignature = null
            items = emptyList()
        }

        fun prepare(nextOwnerSeed: OwnerSeed): Boolean {
            if (ownerSeed == nextOwnerSeed) return false
            val changed = items.isNotEmpty()
            ownerSeed = nextOwnerSeed
            completedSignature = null
            items = emptyList()
            return changed
        }

        fun applyBuild(signature: String, build: RailBuild): RailApply {
            val previous = items
            if (!build.transientFailure) {
                items = build.items
                completedSignature = signature
                return RailApply(items != previous, ReleaseCalendarRailOutcome.UPDATED)
            }

            // A transient partial/empty response may retain only this rail's cache for the exact same
            // owner+seed key. A changed key was already cleared by prepare(), so cross-profile/seed restore
            // is impossible. Leave the completion signature unset so the next Home emission retries.
            if (previous.isNotEmpty()) {
                completedSignature = null
                return RailApply(changed = false, ReleaseCalendarRailOutcome.RETAINED_AFTER_TRANSIENT_FAILURE)
            }
            items = build.items
            completedSignature = null
            return RailApply(
                changed = items != previous,
                outcome = ReleaseCalendarRailOutcome.PARTIAL_AFTER_TRANSIENT_FAILURE,
            )
        }
    }

    private data class UpcomingItem(val item: MetaItem, val date: Instant)
    private data class RailBuild(val items: List<MetaItem>, val transientFailure: Boolean)
    private data class RailApply(val changed: Boolean, val outcome: ReleaseCalendarRailOutcome)

    private sealed interface MetaLookup {
        data class Found(val meta: JSONObject) : MetaLookup
        object Missing : MetaLookup
        object TransientFailure : MetaLookup
    }

    private sealed interface ItemLookup {
        data class Found(val upcoming: UpcomingItem?) : ItemLookup
        object TransientFailure : ItemLookup
    }

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

internal object HttpUpcomingMetaFetcher : UpcomingMetaFetcher {
    private const val TIMEOUT_MS = 12_000L
    private const val MAX_META_BYTES = 8 * 1024 * 1024
    private val client = OkHttpClient.Builder()
        .connectTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .readTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .callTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .followRedirects(true)
        .build()

    override suspend fun fetch(base: String, type: MediaType, id: String): UpcomingMetaResponse =
        suspendCancellableCoroutine { continuation ->
            val root = base.toHttpUrlOrNull()
            val url = root?.newBuilder()
                ?.addPathSegment("meta")
                ?.addPathSegment(type.id)
                ?.addPathSegment("$id.json")
                ?.build()
            if (url == null) {
                continuation.resume(UpcomingMetaResponse.Success(null))
                return@suspendCancellableCoroutine
            }
            val call = client.newCall(Request.Builder().url(url).get().build())
            val resumed = java.util.concurrent.atomic.AtomicBoolean(false)
            fun resumeOnce(result: UpcomingMetaResponse) {
                if (continuation.isActive && resumed.compareAndSet(false, true)) continuation.resume(result)
            }
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    resumeOnce(UpcomingMetaResponse.TransientFailure)
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = try {
                        response.use {
                            val body = it.body
                            when {
                                it.code == 404 -> UpcomingMetaResponse.Success(null)
                                !it.isSuccessful || body == null || body.contentLength() > MAX_META_BYTES -> {
                                    UpcomingMetaResponse.TransientFailure
                                }
                                else -> {
                                    val bytes = readBounded(body)
                                    if (bytes == null) {
                                        UpcomingMetaResponse.TransientFailure
                                    } else {
                                        runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }
                                            .fold(
                                                onSuccess = { parsed -> UpcomingMetaResponse.Success(parsed) },
                                                onFailure = { UpcomingMetaResponse.TransientFailure },
                                            )
                                    }
                                }
                            }
                        }
                    } catch (_: Exception) {
                        // Covers the whole read + Response.close path. A truncated body commonly throws from
                        // source.read; a close failure must terminate identically instead of escaping the
                        // callback and stranding the suspended coroutine (and its semaphore permit).
                        UpcomingMetaResponse.TransientFailure
                    }
                    resumeOnce(result)
                }
            })
        }

    private fun readBounded(body: ResponseBody): ByteArray? {
        val source = body.source()
        val buffer = Buffer()
        val limit = MAX_META_BYTES + 1L
        while (buffer.size < limit) {
            val read = source.read(buffer, limit - buffer.size)
            if (read == -1L) break
        }
        return if (buffer.size > MAX_META_BYTES) null else buffer.readByteArray()
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
