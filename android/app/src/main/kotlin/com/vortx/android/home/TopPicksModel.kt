package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.person.TMDBPersonClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal const val TOP_PICKS_CATALOG_ID = "vortx.home.topPicks"

internal data class TopPicksRefresh(val items: List<MetaItem>, val changed: Boolean)

/** Profile-local Top Picks builder. Network work happens only when the ordered history/owned set changes. */
internal class TopPicksModel(
    private val similar: suspend (MetaItem) -> List<MetaItem> = TopPicksClient::similar,
) {
    private var signature: String? = null
    private var cachedItems: List<MetaItem> = emptyList()

    suspend fun refresh(
        continueWatching: List<MetaItem>,
        library: List<MetaItem>,
        onInvalidated: () -> Unit = {},
    ): TopPicksRefresh {
        val visibleBeforeRequest = cachedItems
        val history = continueWatching + library
        val seeds = history.asSequence()
            .filter { it.id.startsWith("tt") }
            .distinctBy { it.id }
            .take(MAX_SEEDS)
            .toList()
        if (seeds.isEmpty()) return replace(emptyList(), null)

        val owned = history.mapTo(linkedSetOf(), MetaItem::id)
        val nextSignature = buildString {
            append(seeds.joinToString(",") { "${it.type.id}:${it.id}" })
            append('|')
            append(owned.sorted().joinToString(","))
        }
        if (nextSignature == signature && cachedItems.isNotEmpty()) {
            return TopPicksRefresh(cachedItems, changed = false)
        }

        // Never show one profile's stale suggestions while a different history is being resolved.
        if (signature != null && signature != nextSignature) {
            cachedItems = emptyList()
            onInvalidated()
        }

        val buckets = coroutineScope {
            seeds.map { seed -> async { similar(seed) } }.awaitAll()
        }
        val seedIds = seeds.mapTo(hashSetOf(), MetaItem::id)
        val added = hashSetOf<String>()
        val merged = ArrayList<MetaItem>(MAX_ITEMS)
        val maxDepth = buckets.maxOfOrNull(List<MetaItem>::size) ?: 0
        outer@ for (depth in 0 until maxDepth) {
            for (bucket in buckets) {
                val item = bucket.getOrNull(depth) ?: continue
                if (item.id in owned || item.id in seedIds || !added.add(item.id)) continue
                merged += item
                if (merged.size == MAX_ITEMS) break@outer
            }
        }
        if (merged.isEmpty()) {
            signature = null
            return TopPicksRefresh(cachedItems, changed = visibleBeforeRequest != cachedItems)
        }
        return replace(merged, nextSignature)
    }

    private fun replace(items: List<MetaItem>, nextSignature: String?): TopPicksRefresh {
        val changed = items != cachedItems
        cachedItems = items
        signature = nextSignature
        return TopPicksRefresh(items, changed)
    }

    private companion object {
        const val MAX_SEEDS = 5
        const val MAX_ITEMS = 20
    }
}

internal fun withTopPicksRail(rows: List<Catalog>, items: List<MetaItem>): List<Catalog> {
    val base = rows.filterNot { it.id == TOP_PICKS_CATALOG_ID }
    if (items.isEmpty()) return base
    val insertion = (base.indexOfFirst { it.id == "continue" } + 1).coerceAtLeast(0)
    return base.toMutableList().apply {
        add(insertion, Catalog(TOP_PICKS_CATALOG_ID, "Top Picks for you", items))
    }
}

/** Keyless TMDB recommendations resolved through Cinemeta into normal playable VortX cards. */
internal object TopPicksClient {
    private const val CINEMETA = "https://v3-cinemeta.strem.io"
    private const val TIMEOUT_MS = 20_000
    private val metadataSlots = Semaphore(8)

    suspend fun similar(seed: MetaItem): List<MetaItem> = coroutineScope {
        TMDBPersonClient.recommendations(seed.id, seed.type).map { id ->
            async { metadataSlots.withPermit { meta(seed.type, id) } }
        }.awaitAll().filterNotNull()
    }

    private suspend fun meta(type: MediaType, id: String): MetaItem? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL("$CINEMETA/meta/${type.id}/$id.json").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = true
                setRequestProperty("accept", "application/json")
            }
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val meta = runCatching { JSONObject(text) }.getOrNull()?.optJSONObject("meta")
                ?: return@withContext null
            val resolvedId = meta.optString("id").takeIf { it.startsWith("tt") } ?: return@withContext null
            val resolvedType = MediaType.fromId(meta.optString("type", type.id))
            val name = meta.optString("name").takeIf { it.isNotBlank() } ?: return@withContext null
            MetaItem(
                id = resolvedId,
                type = resolvedType,
                name = name,
                poster = meta.optString("poster").takeIf { it.isNotBlank() },
                year = meta.optString("releaseInfo").take(4).takeIf { it.length == 4 },
                description = meta.optString("description").takeIf { it.isNotBlank() },
                background = meta.optString("background").takeIf { it.isNotBlank() },
                imdbRating = meta.optString("imdbRating").takeIf { it.isNotBlank() },
            )
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }
}
