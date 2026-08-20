package com.vortx.android.communityjs

import android.content.Context
import com.vortx.android.catalog.CatalogTmdbEdge
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/** Auxiliary source which turns enabled community-provider results into ordinary ranked source groups. */
class CommunityJsProviderSource(context: Context) {
    private val store = CommunityJsProviderStore(context)
    private val runtime = CommunityJsRuntime(context)
    private val _groups = MutableStateFlow<List<StreamGroup>>(emptyList())
    val groups: StateFlow<List<StreamGroup>> = _groups
    private val _epoch = MutableStateFlow(0)
    val epoch: StateFlow<Int> = _epoch
    private val _settled = MutableStateFlow(true)
    val settled: StateFlow<Boolean> = _settled
    private val activeGeneration = AtomicLong(-1L)

    fun refresh(
        scope: CoroutineScope,
        imdbId: String?,
        mediaType: String,
        season: Int?,
        episode: Int?,
        requestGeneration: Long,
    ) {
        activeGeneration.set(requestGeneration)
        _settled.value = false
        scope.launch(Dispatchers.IO) {
            val tmdbId = resolveTmdbId(imdbId, mediaType)
            val result = if (tmdbId == null) emptyList() else store.providers()
                .filter { it.enabled && it.supports(mediaType) }
                .mapNotNull { provider ->
                    when (val outcome = runtime.execute(CommunityJsRuntime.Invocation(provider, tmdbId, mediaType, season, episode))) {
                        is CommunityJsRuntime.Result.Success -> mapGroup(provider, outcome.streams)
                        is CommunityJsRuntime.Result.Failure -> null
                    }
                }
            // Publication is fenced immediately before mutation. A cancelled or slower earlier request must
            // never replace a newer title's sources merely because it completed afterward.
            if (requestGeneration >= 0L && activeGeneration.get() == requestGeneration) {
                _groups.value = result
                _epoch.value += 1
                _settled.value = true
            }
        }
    }

    fun reset() {
        activeGeneration.incrementAndGet()
        _groups.value = emptyList()
        _epoch.value += 1
        _settled.value = true
    }

    private suspend fun resolveTmdbId(imdbId: String?, mediaType: String): String? {
        val imdb = imdbId?.takeIf { it.startsWith("tt") } ?: return null
        val result = CatalogTmdbEdge.getJson("/find/$imdb?external_source=imdb_id") ?: return null
        val arrayKey = if (mediaType == "tv") "tv_results" else "movie_results"
        return result.optJSONArray(arrayKey)?.optJSONObject(0)?.optInt("id", 0)?.takeIf { it > 0 }?.toString()
    }

    companion object {
        internal fun mapGroup(provider: CommunityJsProviderStore.Provider, streams: List<CommunityJsRuntime.ProviderStream>): StreamGroup? {
        val mapped = streams.mapIndexed { index, stream ->
            val providerLabel = stream.name ?: provider.name
            val title = listOfNotNull(providerLabel, stream.quality).joinToString(" · ").ifBlank { provider.name }
            val description = listOfNotNull(stream.title, stream.quality, stream.size).joinToString(" · ").ifBlank { null }
            StreamSource(
                id = "community-js:${provider.id}:$index:${stream.url.hashCode()}",
                addon = provider.name,
                title = title,
                description = description,
                quality = stream.quality,
                url = stream.url,
                vortxProvider = "community-js:${provider.id}",
                requestHeaders = stream.headers,
                externalSubtitles = stream.subtitles.map(CommunityJsRuntime.Subtitle::url),
            )
        }
        return mapped.takeIf { it.isNotEmpty() }?.let { StreamGroup(addon = provider.name, streams = it, base = "community-js:${provider.id}") }
    }

        /** Appends provider groups after built-in source lanes, then the existing ranker chooses final order. */
        fun merge(groups: List<StreamGroup>, providers: List<StreamGroup>): List<StreamGroup> {
            if (providers.isEmpty()) return groups
            val seen = groups.flatMap { it.streams }.mapNotNull { it.url }.toHashSet()
            val fresh = providers.mapNotNull { group ->
                val streams = group.streams.filter { stream -> stream.url?.let(seen::add) == true }
                group.copy(streams = streams).takeIf { it.streams.isNotEmpty() }
            }
            return groups + fresh
        }
    }
}
