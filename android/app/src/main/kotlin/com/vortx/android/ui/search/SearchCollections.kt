package com.vortx.android.ui.search

import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTile

/** Only existing, visible collection targets whose localized titles match the actual query. */
internal fun searchCollectionTiles(
    query: String,
    snapshot: CollectionsHubSnapshot,
    title: (CollectionsHubLabel) -> String,
): List<CollectionsHubTile> {
    if (!isSearchQueryEligible(query) || !snapshot.enabled) return emptyList()
    val needle = normalizeForSuggestion(query)
    return (snapshot.discover + snapshot.streaming + snapshot.genres + snapshot.decades)
        .distinctBy { it.id }
        .filter { normalizeForSuggestion(title(it.title)).contains(needle) }
}
