package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
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

    suspend fun refresh(
        continueWatching: List<MetaItem>,
        library: List<MetaItem>,
        onInvalidated: () -> Unit = {},
    ): BecauseYouWatchedRefresh {
        val visibleBefore = cachedRail
        val history = continueWatching + library
        val seeds = history.asSequence()
            .filter { it.id.startsWith("tt") }
            .distinctBy(MetaItem::id)
            .take(MAX_SEEDS)
            .toList()
        if (seeds.isEmpty()) return replace(null, null)

        val owned = history.mapTo(linkedSetOf(), MetaItem::id)
        val nextSignature = buildString {
            append(seeds.joinToString(",") { "${it.type.id}:${it.id}:${it.name}" })
            append('|')
            append(owned.sorted().joinToString(","))
        }
        if (signature == nextSignature && cachedRail != null) {
            return BecauseYouWatchedRefresh(cachedRail, changed = false)
        }

        // A new history owner or seed set must never display the previous owner's personalized row while
        // the replacement request is in flight. Same-signature retries retain their already-owned row.
        if (signature != null && signature != nextSignature) {
            cachedRail = null
            onInvalidated()
        }

        val buckets = try {
            coroutineScope {
                seeds.map { seed ->
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
            return BecauseYouWatchedRefresh(cachedRail, changed = visibleBefore != cachedRail)
        }
        return replace(
            Catalog(
                id = BECAUSE_YOU_WATCHED_CATALOG_ID,
                title = "Because you watched ${seeds.first().name}",
                items = merged,
            ),
            nextSignature,
        )
    }

    fun clear(): BecauseYouWatchedRefresh = replace(null, null)

    private fun replace(rail: Catalog?, nextSignature: String?): BecauseYouWatchedRefresh {
        val changed = rail != cachedRail
        cachedRail = rail
        signature = nextSignature
        return BecauseYouWatchedRefresh(rail, changed)
    }

    private companion object {
        const val MAX_SEEDS = 4
        const val MAX_ITEMS = 20
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
