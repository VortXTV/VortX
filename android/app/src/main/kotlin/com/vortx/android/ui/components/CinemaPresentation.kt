package com.vortx.android.ui.components

import com.vortx.android.model.MetaItem
import com.vortx.android.model.MediaType

/**
 * The compact, data-honest footer for touch catalog cards. It intentionally consumes only preview
 * metadata already carried by [MetaItem]: a catalog tile must never initiate a detail fetch merely to
 * look more complete. Keeping this formatter in the presentation layer means Home, Discover, Search,
 * and Library describe the same title in the same order.
 */
fun cinemaCardFacts(item: MetaItem): String? = listOfNotNull(
    item.year?.takeIf { it.isNotBlank() },
    item.previewRuntimeMinutes?.takeIf { it > 0 }?.let { "${it}m" },
    item.previewSeasonCount?.takeIf { it > 0 }?.let { "$it ${if (it == 1) "season" else "seasons"}" },
    item.preferredEpisode?.takeIf { it.season >= 0 && it.episode > 0 }?.let {
        "S${it.season} · E${it.episode}".takeUnless { _ ->
            Regex("\\bS${it.season}\\s*(?:·\\s*)?E${it.episode}\\b", RegexOption.IGNORE_CASE)
                .containsMatchIn(item.caption.orEmpty())
        }
    },
    item.imdbRating?.takeIf { it.isNotBlank() }?.let { "★ $it" },
    item.caption?.takeIf { it.isNotBlank() },
).distinct().joinToString(" · ").ifBlank { item.type.label }

/** Live/channel cards keep their existing route; Quick View owns only playable title previews. */
fun cinemaCardOpensQuickView(item: MetaItem, enabled: Boolean): Boolean =
    enabled && item.type in setOf(MediaType.MOVIE, MediaType.SERIES)

/** Uses only the preview's artwork. Opening a card must not start metadata/provider work. */
fun cinemaLandscapeArtwork(item: MetaItem): String? =
    item.background?.takeIf(String::isNotBlank) ?: item.poster?.takeIf(String::isNotBlank)
