package com.vortx.android.mediaserver

import com.vortx.android.home.ExternalMetadataResolver
import com.vortx.android.home.ExternalSeed
import com.vortx.android.integrations.IntegrationsHttp
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

internal const val MEDIA_SERVER_CATALOG_PREFIX = "vortx.home.mediaServers:"

internal data class MediaServerRailsRefresh(
    val rails: List<Catalog>,
    val changed: Boolean,
)

internal interface MediaServerCatalogSource {
    fun configurationGeneration(): Long?
    suspend fun fetch(expectedGeneration: Long): Result<List<Catalog>>
}

/** Cached, generation-fenced Home rails from the currently connected Plex/Jellyfin/Emby servers. */
internal class MediaServerCatalogsModel(
    private val source: MediaServerCatalogSource = RepositoryMediaServerCatalogSource,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val refreshMutex = Mutex()
    private val stateLock = Any()
    private var revision = 0L
    private var generation: Long? = null
    private var lastSuccessAt: Long? = null
    private var cachedRails: List<Catalog> = emptyList()

    suspend fun refresh(): MediaServerRailsRefresh = refreshMutex.withLock {
        val expected = source.configurationGeneration()
        val plan = synchronized(stateLock) {
            val visibleBefore = cachedRails
            if (expected == null) {
                resetLocked(null)
                return MediaServerRailsRefresh(emptyList(), visibleBefore.isNotEmpty())
            }
            if (generation != expected) resetLocked(expected)
            val last = lastSuccessAt
            if (last != null && nowMillis() - last < REFRESH_INTERVAL_MS) {
                return MediaServerRailsRefresh(cachedRails, visibleBefore != cachedRails)
            }
            FetchPlan(expected, visibleBefore, revision)
        }

        val result = source.fetch(plan.expectedGeneration)
        synchronized(stateLock) {
            if (revision != plan.revision) {
                return@synchronized MediaServerRailsRefresh(cachedRails, plan.visibleBefore != cachedRails)
            }
            if (source.configurationGeneration() != plan.expectedGeneration) {
                resetLocked(null)
                return@synchronized MediaServerRailsRefresh(emptyList(), plan.visibleBefore.isNotEmpty())
            }
            result.onSuccess { rails ->
                cachedRails = rails
                lastSuccessAt = nowMillis()
            }
            MediaServerRailsRefresh(cachedRails, plan.visibleBefore != cachedRails)
        }
    }

    fun clear(): MediaServerRailsRefresh = synchronized(stateLock) {
        val hadRows = cachedRails.isNotEmpty()
        resetLocked(null)
        MediaServerRailsRefresh(emptyList(), hadRows)
    }

    private fun resetLocked(nextGeneration: Long?) {
        revision += 1L
        generation = nextGeneration
        lastSuccessAt = null
        cachedRails = emptyList()
    }

    private data class FetchPlan(
        val expectedGeneration: Long,
        val visibleBefore: List<Catalog>,
        val revision: Long,
    )

    private companion object {
        const val REFRESH_INTERVAL_MS = 30 * 60 * 1000L
    }
}

internal fun withMediaServerRails(rows: List<Catalog>, rails: List<Catalog>): List<Catalog> {
    val base = rows.filterNot { it.id.startsWith(MEDIA_SERVER_CATALOG_PREFIX) }
    if (rails.isEmpty()) return base
    val anchor = base.indexOfFirst { it.id == "vortx.home.simklWatchlist" }
        .takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.traktWatchlist" }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.becauseYouWatched" }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.topPicks" }.takeIf { it >= 0 }
        ?: -1
    return base.toMutableList().apply { addAll(anchor + 1, rails.filter { it.items.isNotEmpty() }) }
}

private object RepositoryMediaServerCatalogSource : MediaServerCatalogSource {
    override fun configurationGeneration(): Long? =
        MediaServerRepository.catalogSnapshot().takeIf { it.configs.isNotEmpty() }?.generation

    override suspend fun fetch(expectedGeneration: Long): Result<List<Catalog>> = try {
        val snapshot = MediaServerRepository.catalogSnapshot()
        check(snapshot.generation == expectedGeneration && snapshot.configs.isNotEmpty()) {
            "Media-server configuration changed"
        }
        val serverResults = coroutineScope {
            snapshot.configs.map { config -> async { fetchServer(config) } }.awaitAll()
        }
        check(MediaServerRepository.catalogSnapshot().generation == expectedGeneration) {
            "Media-server configuration changed"
        }
        if (serverResults.none(ServerFetch::answered)) error("No media server answered")
        Result.success(serverResults.flatMap(ServerFetch::rails))
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

    private suspend fun fetchServer(config: MediaServerConfig): ServerFetch = coroutineScope {
        val movieWork = async { fetchType(config, MediaType.MOVIE) }
        val seriesWork = async { fetchType(config, MediaType.SERIES) }
        val movie = movieWork.await()
        val series = seriesWork.await()
        val rails = buildList {
            movie.getOrNull()?.takeIf(List<ExternalSeed>::isNotEmpty)?.let { seeds ->
                add(catalog(config, MediaType.MOVIE, seeds))
            }
            series.getOrNull()?.takeIf(List<ExternalSeed>::isNotEmpty)?.let { seeds ->
                add(catalog(config, MediaType.SERIES, seeds))
            }
        }
        ServerFetch(answered = movie.isSuccess || series.isSuccess, rails = rails)
    }

    private suspend fun catalog(
        config: MediaServerConfig,
        type: MediaType,
        seeds: List<ExternalSeed>,
    ): Catalog {
        val resolved = ExternalMetadataResolver.resolve(seeds.distinctBy(ExternalSeed::imdb).take(MAX_ITEMS))
        return Catalog(
            id = "$MEDIA_SERVER_CATALOG_PREFIX${config.id}:${type.id}",
            title = "Recently added on ${config.displayName}",
            items = resolved,
        )
    }

    private suspend fun fetchType(config: MediaServerConfig, type: MediaType): Result<List<ExternalSeed>> =
        when (config.kind) {
            MediaServerKind.PLEX -> fetchPlex(config, type)
            MediaServerKind.JELLYFIN, MediaServerKind.EMBY -> fetchJellyfin(config, type)
        }

    private suspend fun fetchJellyfin(
        config: MediaServerConfig,
        type: MediaType,
    ): Result<List<ExternalSeed>> = requestResult {
        val base = MediaServerResolve.normalizedBase(config.baseUrl) ?: error("Invalid media-server URL")
        val include = if (type == MediaType.MOVIE) "Movie" else "Series"
        val user = encode(config.userId)
        val response = IntegrationsHttp.request(
            method = "GET",
            urlString = "$base/Users/$user/Items/Latest?IncludeItemTypes=$include&Fields=ProviderIds&Limit=$MAX_ITEMS",
            headers = mapOf(
                "Authorization" to "MediaBrowser Token=\"${config.apiKey}\", Client=\"VortX\", Device=\"VortX\", Version=\"${JellyfinClient.APP_VERSION}\"",
                "X-Emby-Token" to config.apiKey,
                "Accept" to "application/json",
            ),
        )
        check(response.isSuccess) { "Media server HTTP ${response.status}" }
        val raw = response.body.trim()
        val array = if (raw.startsWith("[")) JSONArray(raw) else JSONObject(raw).optJSONArray("Items") ?: JSONArray()
        buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val imdb = item.optJSONObject("ProviderIds")?.keys()?.asSequence()
                    ?.firstOrNull { it.equals("imdb", ignoreCase = true) }
                    ?.let { item.optJSONObject("ProviderIds")?.optString(it) }
                    ?.takeIf(::isImdb) ?: continue
                add(ExternalSeed(imdb, type, item.optString("Name").takeIf(String::isNotBlank) ?: imdb))
                if (size == MAX_ITEMS) break
            }
        }
    }

    private suspend fun fetchPlex(
        config: MediaServerConfig,
        type: MediaType,
    ): Result<List<ExternalSeed>> = requestResult {
        val kind = if (type == MediaType.MOVIE) "1" else "2"
        val bases = config.urls.ifEmpty { listOf(config.baseUrl) }
            .mapNotNull(MediaServerResolve::normalizedBase)
        var lastStatus = 0
        for (base in bases) {
            val response = IntegrationsHttp.request(
                method = "GET",
                urlString = "$base/library/recentlyAdded?type=$kind&includeGuids=1",
                headers = mapOf(
                    "X-Plex-Token" to config.apiKey,
                    "X-Plex-Product" to PlexClient.PRODUCT,
                    "X-Plex-Client-Identifier" to MediaServerRepository.plexClientId,
                    "Accept" to "application/json",
                ),
            )
            lastStatus = response.status
            if (!response.isSuccess) continue
            val metadata = JSONObject(response.body)
                .optJSONObject("MediaContainer")?.optJSONArray("Metadata") ?: JSONArray()
            return@requestResult buildList {
                for (index in 0 until metadata.length()) {
                    val item = metadata.optJSONObject(index) ?: continue
                    val imdb = plexImdb(item) ?: continue
                    add(ExternalSeed(imdb, type, item.optString("title").takeIf(String::isNotBlank) ?: imdb))
                    if (size == MAX_ITEMS) break
                }
            }
        }
        error("Plex HTTP $lastStatus")
    }

    private fun plexImdb(item: JSONObject): String? {
        item.optString("guid").substringAfter("imdb://", "").takeIf(::isImdb)?.let { return it }
        val guids = item.optJSONArray("Guid") ?: return null
        for (index in 0 until guids.length()) {
            val id = guids.optJSONObject(index)?.optString("id").orEmpty()
                .substringAfter("imdb://", "")
            if (isImdb(id)) return id
        }
        return null
    }

    private suspend fun <T> requestResult(block: suspend () -> T): Result<T> = try {
        Result.success(block())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")
    private fun isImdb(value: String): Boolean =
        value.startsWith("tt") && value.length > 2 && value.drop(2).all(Char::isDigit)

    private data class ServerFetch(val answered: Boolean, val rails: List<Catalog>)
    private const val MAX_ITEMS = 20
}
