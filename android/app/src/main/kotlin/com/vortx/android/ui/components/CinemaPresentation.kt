package com.vortx.android.ui.components

import com.vortx.android.model.MetaItem

/**
 * The compact, data-honest footer for touch catalog cards. It intentionally consumes only preview
 * metadata already carried by [MetaItem]: a catalog tile must never initiate a detail fetch merely to
 * look more complete. Keeping this formatter in the presentation layer means Home, Discover, Search,
 * and Library describe the same title in the same order.
 */
fun cinemaCardFacts(item: MetaItem): String? = listOfNotNull(
    item.previewRuntimeMinutes?.takeIf { it > 0 }?.let { "${it}m" },
    item.year?.takeIf { it.isNotBlank() },
    item.imdbRating?.takeIf { it.isNotBlank() }?.let { "★ $it" },
    item.caption?.takeIf { it.isNotBlank() },
    // Type is an honest fallback when a sparse add-on omits every preview fact.
    item.type.label.takeIf { item.previewRuntimeMinutes == null && item.year.isNullOrBlank() && item.imdbRating.isNullOrBlank() },
).distinct().joinToString(" · ").ifBlank { null }
