package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.person.TMDBPersonClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

internal const val BECAUSE_YOU_WATCHED_CATALOG_ID = "vortx.home.becauseYouWatched"

internal data class BecauseYouWatchedRefresh(
    val rail: Catalog?,
    val changed: Boolean,
)

/** A profile-history recommendation rail named after the most recent eligible title. */
internal class BecauseYouWatchedModel(
    private val similar: suspend (MetaItem) -> List<MetaItem> = TopPicksClient::similar,
) {
    private var signature: String? = null
    private var cachedRail: Catalog? = null
    private var inFlightSignature: String? = null
    private var requestGeneration = 0L
    /** A profile UUID alone is not an ownership boundary: account/principal/history-slot changes can reuse it. */
    private var activeOwnerKey: String? = null

    suspend fun refresh(
        continueWatching: List<MetaItem>,
        library: List<MetaItem>,
        ownerKey: String = LOCAL_OWNER_KEY,
        onInvalidated: () -> Unit = {},
    ): BecauseYouWatchedRefresh {
        val history = continueWatching + library
        val seeds = history.asSequence()
            .filter(::hasWatchEvidence)
            .filter { supportsResolution(it.id) }
            .distinctBy(MetaItem::id)
            .take(MAX_SEEDS)
            .toList()
        val ownerChanged = activeOwnerKey != null && activeOwnerKey != ownerKey

        // An empty history is authoritative: do not leave the previous owner's rail on screen. This path
        // also invalidates a still-running request through requestGeneration below.
        if (seeds.isEmpty()) {
            requestGeneration += 1
            inFlightSignature = null
            activeOwnerKey = ownerKey
            val cleared = replace(null, null)
            if (ownerChanged) onInvalidated()
            return cleared
        }

        val owned = history.mapNotNullTo(linkedSetOf()) { it.id.takeIf(String::isNotBlank) }
        val nextSignature = buildString {
            append(ownerKey)
            append('|')
            append(seeds.joinToString(",") {
                "${it.type.id}:${it.id}:${it.name}:${it.watched}:${it.progress ?: 0f}"
            })
            append('|')
            append(owned.sorted().joinToString(","))
        }
        if (!ownerChanged && signature == nextSignature && cachedRail != null) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }
        if (!ownerChanged && inFlightSignature == nextSignature) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }

        val request = ++requestGeneration
        inFlightSignature = nextSignature
        val visibleBefore = cachedRail

        // A changed owner or history must never display the previous owner's personalized row while the
        // replacement request is in flight. The generation check below prevents uncancellable provider work
        // from publishing after a later refresh wins.
        if (ownerChanged || (signature != null && signature != nextSignature)) {
            cachedRail = null
            if (ownerChanged) signature = null
            onInvalidated()
        }
        activeOwnerKey = ownerKey

        val resolvedSeeds = try {
            coroutineScope {
                seeds.map { seed ->
                    async { resolveSeed(seed) }
                }.awaitAll().filterNotNull()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
        if (requestGeneration != request) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }
        if (resolvedSeeds.isEmpty()) {
            inFlightSignature = null
            signature = null
            return BecauseYouWatchedRefresh(cachedRail, changed = visibleBefore != cachedRail)
        }

        val buckets = try {
            coroutineScope {
                resolvedSeeds.map { seed ->
                    async {
                        try {
                            similar(seed)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Throwable) {
                            emptyList()
                        }
                    }
                }.awaitAll()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
        if (requestGeneration != request) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }

        val seedIds = buildSet {
            seeds.forEach { add(it.id) }
            resolvedSeeds.forEach { add(it.id) }
        }
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

        if (requestGeneration != request) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }
        if (merged.isEmpty()) {
            inFlightSignature = null
            signature = null
            return BecauseYouWatchedRefresh(cachedRail, changed = visibleBefore != cachedRail)
        }
        inFlightSignature = null
        return replace(
            Catalog(
                id = BECAUSE_YOU_WATCHED_CATALOG_ID,
                title = "Because you watched ${resolvedSeeds.first().name}",
                items = merged,
            ),
            nextSignature,
        )
    }

    fun clear(): BecauseYouWatchedRefresh {
        requestGeneration += 1
        inFlightSignature = null
        activeOwnerKey = null
        return replace(null, null)
    }

    private suspend fun resolveSeed(seed: MetaItem): MetaItem? {
        if (seed.id.startsWith("tt")) return seed
        val resolverID = normalizedTmdbID(seed.id) ?: return null
        val imdb = TMDBPersonClient.imdbId(resolverID, seed.type) ?: return null
        return seed.copy(id = imdb)
    }

    private fun replace(rail: Catalog?, nextSignature: String?): BecauseYouWatchedRefresh {
        val nextRail = rail?.let(::preserveArtwork)
        val changed = nextRail != cachedRail
        cachedRail = nextRail
        signature = nextSignature
        return BecauseYouWatchedRefresh(nextRail, changed)
    }

    private fun preserveArtwork(rail: Catalog): Catalog {
        val previous = cachedRail ?: return rail
        val oldByID = previous.items.associateBy(MetaItem::id)
        return rail.copy(
            items = rail.items.map { item ->
                if (item.poster.isNullOrBlank()) {
                    val old = oldByID[item.id]
                    if (!old?.poster.isNullOrBlank()) item.copy(poster = old?.poster) else item
                } else {
                    item
                }
            },
        )
    }

    private companion object {
        const val MAX_SEEDS = 4
        const val MAX_ITEMS = 20
        const val LOCAL_OWNER_KEY = "local"

        private fun hasWatchEvidence(item: MetaItem): Boolean =
            item.watched || (item.progress ?: 0f) > 0f

        /** Only shapes with a verified Android resolver are admitted; unknown/anime-only ids fail closed. */
        private fun supportsResolution(id: String): Boolean =
            id.startsWith("tt") || normalizedTmdbID(id) != null

        private fun normalizedTmdbID(id: String): String? {
            val parts = id.split(':')
            if (parts.size == 2 && parts[0].equals("tmdb", ignoreCase = true)) {
                return parts[1].toIntOrNull()?.takeIf { it > 0 }?.let { "tmdb:$it" }
            }
            if (parts.size == 3 && parts[0].equals("tmdb", ignoreCase = true) &&
                parts[1].lowercase() in setOf("movie", "tv", "series")
            ) {
                return parts[2].toIntOrNull()?.takeIf { it > 0 }?.let { "tmdb:$it" }
            }
            return id.toIntOrNull()?.takeIf { it > 0 }?.let { "tmdb:$it" }
        }
    }
}

internal fun withBecauseYouWatchedRail(rows: List<Catalog>, rail: Catalog?): List<Catalog> {
    val base = rows.filterNot { it.id == BECAUSE_YOU_WATCHED_CATALOG_ID }
    if (rail == null || rail.items.isEmpty()) return base
    val anchor = base.indexOfFirst { it.id == TOP_PICKS_CATALOG_ID }
        .takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "continue" }.takeIf { it >= 0 }
        ?: -1
    return base.toMutableList().apply { add(anchor + 1, rail) }
}
