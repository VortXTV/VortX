package com.vortx.android.ui

import com.vortx.android.home.HomeRail
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

/**
 * The insertion index in [catalogs] where the Collections hub belongs, derived from the Customize-Home rail
 * [order]. The hub is not a catalog, so it cannot ride `HomeRailPreferences.arrange`; instead it slots right
 * after the last catalog whose rail is ordered before COLLECTIONS_HUB (Continue Watching is always pinned
 * first). Lets the phone + TV Home place the hub at its user-chosen slot instead of a hardcoded top pin.
 */
internal fun collectionsHubSlot(catalogs: List<Catalog>, order: List<HomeRail>): Int {
    val hubRank = order.indexOf(HomeRail.COLLECTIONS_HUB)
    if (hubRank < 0) return catalogs.size
    var index = 0
    for (catalog in catalogs) {
        if (catalog.id == HomeRail.CONTINUE_CATALOG_ID) {
            index++
            continue
        }
        val rank = order.indexOf(HomeRail.forCatalog(catalog))
        if (rank in 0 until hubRank) index++ else break
    }
    return index
}

/** One Home LazyColumn row: an add-on / client catalog, or the Collections hub band placed at its slot. */
internal sealed interface HomeRowItem {
    data class CatalogRow(val catalog: Catalog) : HomeRowItem
    data object HubRow : HomeRowItem
}

/** Interleave the hub band into the catalog list at [hubSlot] (null hides it). Shared by phone + TV Home. */
internal fun homeRowsWithHub(catalogs: List<Catalog>, hubSlot: Int?): List<HomeRowItem> = buildList {
    catalogs.forEachIndexed { index, catalog ->
        if (hubSlot != null && index == hubSlot) add(HomeRowItem.HubRow)
        add(HomeRowItem.CatalogRow(catalog))
    }
    if (hubSlot != null && hubSlot >= catalogs.size) add(HomeRowItem.HubRow)
}

/** Stable Compose key for a [HomeRowItem]. The hub keeps its historical key so its position animates. */
internal fun homeRowKey(row: HomeRowItem): String = when (row) {
    is HomeRowItem.CatalogRow -> row.catalog.id
    HomeRowItem.HubRow -> "vortx.home.collectionsHub"
}
