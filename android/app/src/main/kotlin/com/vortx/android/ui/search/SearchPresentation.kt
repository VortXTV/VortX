package com.vortx.android.ui.search

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState

internal enum class SearchResultSectionKind { MOVIES, SERIES, OTHER }

internal data class SearchResultSection(
    val kind: SearchResultSectionKind?,
    val items: List<MetaItem>,
)

internal enum class SearchEmptyMessage { IDLE_GUIDANCE, NO_MATCHES }

internal fun isSearchQueryEligible(query: String): Boolean = query.trim().length >= MIN_SEARCH_QUERY_LENGTH

internal fun searchResultItemKey(item: MetaItem): String =
    "search-result-item:${item.type.id}:${item.id}"

internal fun searchResultSectionHeaderKey(kind: SearchResultSectionKind): String =
    "search-result-section-header:${kind.name}"

internal fun searchResultSections(items: List<MetaItem>): List<SearchResultSection> {
    val deduped = items.distinctBy(::searchResultItemKey)
    return listOf(
        SearchResultSection(SearchResultSectionKind.MOVIES, deduped.filter { it.type == MediaType.MOVIE }),
        SearchResultSection(SearchResultSectionKind.SERIES, deduped.filter { it.type == MediaType.SERIES }),
        SearchResultSection(
            SearchResultSectionKind.OTHER,
            deduped.filter { it.type != MediaType.MOVIE && it.type != MediaType.SERIES },
        ),
    ).filter { it.items.isNotEmpty() }
}

internal fun searchEmptyMessage(query: String, state: UiState<List<MetaItem>>): SearchEmptyMessage? {
    val items = (state as? UiState.Success)?.data ?: return null
    if (items.isNotEmpty()) return null
    return if (isSearchQueryEligible(query)) {
        SearchEmptyMessage.NO_MATCHES
    } else {
        SearchEmptyMessage.IDLE_GUIDANCE
    }
}

private const val MIN_SEARCH_QUERY_LENGTH = 2
