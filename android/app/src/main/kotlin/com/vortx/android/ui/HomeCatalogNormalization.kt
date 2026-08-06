package com.vortx.android.ui

import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem

/** Stable Compose identity for one poster inside a rail. */
internal fun homeCatalogItemKey(item: MetaItem): String = "${item.type.name}|${item.id}"

/** Keep the first engine-ranked occurrence of each type/id identity without reordering survivors. */
internal fun normalizeHomeItems(items: List<MetaItem>): List<MetaItem> =
    items.distinctBy(::homeCatalogItemKey)

/**
 * One normalization boundary shared by phone and TV Home. Catalog ids are Compose row keys, so a
 * duplicate must be removed before either LazyColumn sees it. First-wins preserves engine rank.
 */
internal fun normalizeHomeCatalogs(catalogs: List<Catalog>): List<Catalog> =
    catalogs.distinctBy { it.id }.map { catalog ->
        val items = normalizeHomeItems(catalog.items)
        if (items.size == catalog.items.size) catalog else catalog.copy(items = items)
    }
