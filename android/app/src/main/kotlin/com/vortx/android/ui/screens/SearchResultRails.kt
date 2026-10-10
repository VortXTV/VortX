package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.LoadingRail
import com.vortx.android.ui.components.PosterRail
import com.vortx.android.ui.components.CollectionsBrowseScreen
import com.vortx.android.ui.components.SearchCollectionsRail
import com.vortx.android.ui.components.rememberDiscoverHub
import com.vortx.android.ui.search.SearchResultSectionKind
import com.vortx.android.ui.search.SearchResultSection
import com.vortx.android.ui.search.isSearchQueryEligible
import com.vortx.android.ui.search.searchCollectionTiles
import com.vortx.android.ui.search.searchEmptyMessage
import com.vortx.android.ui.search.searchResultSections
import com.vortx.android.ui.search.textResourceId
import com.vortx.android.ui.search.titleResourceId
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/** Search shares Home's poster rails; arriving results stay usable while other add-ons settle. */
@Composable
internal fun SearchResultRails(
    query: String,
    items: List<MetaItem>,
    isLoading: Boolean,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    errorMessage: String? = null,
) {
    val collections = if (isSearchQueryEligible(query)) rememberDiscoverHub() else null
    val snapshot = collections?.snapshot?.collectAsStateWithLifecycle()?.value
    val browse = collections?.browse?.collectAsStateWithLifecycle()?.value
    val scope = rememberCoroutineScope()
    LaunchedEffect(query, collections) { collections?.closeBrowse() }
    if (collections != null && browse?.target != null) {
        CollectionsBrowseScreen(
            state = browse,
            onBack = collections::closeBrowse,
            onItem = onItem,
            onCategory = { scope.launch { collections.selectCategory(it) } },
            onRetry = { scope.launch { collections.retry() } },
            onLoadMore = { scope.launch { collections.loadMore() } },
            modifier = modifier,
        )
        return
    }
    val context = LocalContext.current
    val collectionTiles = snapshot?.let { value -> searchCollectionTiles(query, value) { label ->
        when (label) {
            is CollectionsHubLabel.Resource -> context.getString(label.resourceId)
            is CollectionsHubLabel.Literal -> label.value
        }
    } }.orEmpty()
    val collectionsLoading = snapshot?.streamingLoading == true
    val sections = searchResultSections(items)
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(vertical = VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        items(sections.filter { it.kind != SearchResultSectionKind.OTHER }, key = { "search-rail:${it.kind}" }) { section ->
            SearchPosterResultRail(section, isLoading, onItem)
        }
        if (isLoading && sections.isEmpty()) {
            item("search-pending-movies") { LoadingRail(stringResource(SearchResultSectionKind.MOVIES.titleResourceId)) }
            item("search-pending-series") { LoadingRail(stringResource(SearchResultSectionKind.SERIES.titleResourceId)) }
        }
        if (collectionTiles.isNotEmpty() && collections != null) {
            item("search-collections") {
                SearchCollectionsRail(collectionTiles) { target -> scope.launch { collections.open(target) } }
            }
        } else if (collectionsLoading) {
            item("search-pending-collections") { LoadingRail(stringResource(R.string.collections_title)) }
        }
        items(sections.filter { it.kind == SearchResultSectionKind.OTHER }, key = { "search-rail:${it.kind}" }) { section ->
            SearchPosterResultRail(section, isLoading, onItem)
        }
        if (errorMessage != null) {
            item("search-addon-error") {
                Text(errorMessage, style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                    modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge))
            }
        } else if (!isLoading && !collectionsLoading && sections.isEmpty() && collectionTiles.isEmpty()) {
            item("search-empty") {
                searchEmptyMessage(query, UiState.Success(items))?.let {
                    EmptyState(stringResource(it.textResourceId))
                }
            }
        }
    }
}

@Composable
private fun SearchPosterResultRail(section: SearchResultSection, isLoading: Boolean, onItem: (MetaItem) -> Unit) {
    PosterRail(
        catalog = Catalog(
            id = "search-rail:${section.kind}",
            title = stringResource(requireNotNull(section.kind).titleResourceId),
            items = section.items,
            statusMessage = "Searching more add-ons…".takeIf { isLoading },
        ),
        onItem = onItem,
    )
}
