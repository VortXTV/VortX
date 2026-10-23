package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.vortx.android.person.PersonSeed
import com.vortx.android.ui.screens.rememberPeopleResults
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.LoadingRail
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.rememberDiscoverHub
import com.vortx.android.ui.search.SearchResultSectionKind
import com.vortx.android.ui.search.SearchResultSection
import com.vortx.android.ui.search.isSearchQueryEligible
import com.vortx.android.ui.search.searchCollectionTiles
import com.vortx.android.ui.search.searchEmptyMessage
import com.vortx.android.ui.search.searchResultItemKey
import com.vortx.android.ui.search.searchResultSections
import com.vortx.android.ui.search.textResourceId
import com.vortx.android.ui.search.titleResourceId
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/** TV keeps its existing focusable poster cards, with one horizontal focus group per result type. */
@Composable
internal fun TvSearchResultRails(
    query: String,
    items: List<MetaItem>,
    isLoading: Boolean,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    errorMessage: String? = null,
) {
    val collections = if (isSearchQueryEligible(query)) rememberDiscoverHub() else null
    val snapshot = collections?.snapshot?.collectAsStateWithLifecycle()?.value
    val browse = collections?.browse?.collectAsStateWithLifecycle()?.value
    val scope = rememberCoroutineScope()
    LaunchedEffect(query, collections) { collections?.closeBrowse() }
    if (collections != null && browse?.target != null) {
        TvCollectionsBrowseScreen(
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
    // A selected person takes over the results with their page (back returns here), like the phone search.
    var personTarget by remember { mutableStateOf<PersonSeed?>(null) }
    LaunchedEffect(query) { personTarget = null }
    personTarget?.let { seed ->
        BackHandler { personTarget = null }
        TvPersonOverlay(seed = seed, onOpenTitle = onItem, onBack = { personTarget = null })
        return
    }
    val people = rememberPeopleResults(query)
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        items(sections.filter { it.kind != SearchResultSectionKind.OTHER }, key = { "tv-search-rail:${it.kind}" }) { section ->
            TvSearchPosterResultRail(section, isLoading, onItem)
        }
        if (isLoading && sections.isEmpty()) {
            item("tv-search-pending-movies") { LoadingRail(stringResource(SearchResultSectionKind.MOVIES.titleResourceId)) }
            item("tv-search-pending-series") { LoadingRail(stringResource(SearchResultSectionKind.SERIES.titleResourceId)) }
        }
        if (collectionTiles.isNotEmpty() && collections != null) {
            item("tv-search-collections") {
                TvSearchCollectionsRail(collectionTiles) { target -> scope.launch { collections.open(target) } }
            }
        } else if (collectionsLoading) {
            item("tv-search-pending-collections") { LoadingRail(stringResource(R.string.collections_title)) }
        }
        items(sections.filter { it.kind == SearchResultSectionKind.OTHER }, key = { "tv-search-rail:${it.kind}" }) { section ->
            TvSearchPosterResultRail(section, isLoading, onItem)
        }
        // People after the titles, as on Apple TV, so the remote reaches the title rails first.
        if (people.isNotEmpty()) {
            item("tv-search-people") {
                Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Text(
                        text = stringResource(R.string.search_people_title),
                        style = VortXTheme.type.sectionTitle,
                        modifier = Modifier.padding(horizontal = TvDimens.edge),
                    )
                    LazyRow(
                        modifier = Modifier.focusGroup(),
                        contentPadding = PaddingValues(horizontal = TvDimens.edge),
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                    ) {
                        items(people) { person ->
                            TvCastTile(person) { personTarget = PersonSeed(person.id, person.name, person.profileUrl) }
                        }
                    }
                }
            }
        }
        if (errorMessage != null) {
            item("tv-search-addon-error") {
                Text(errorMessage, style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                    modifier = Modifier.padding(horizontal = TvDimens.edge))
            }
        } else if (!isLoading && !collectionsLoading && sections.isEmpty() && collectionTiles.isEmpty()) {
            item("tv-search-empty") {
                searchEmptyMessage(query, UiState.Success(items))?.let { TvEmpty(stringResource(it.textResourceId)) }
            }
        }
    }
}

@Composable
private fun TvSearchPosterResultRail(section: SearchResultSection, isLoading: Boolean, onItem: (MetaItem) -> Unit) {
    Column(Modifier.focusGroup(), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(stringResource(requireNotNull(section.kind).titleResourceId), style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge))
        if (isLoading) Text("Searching more add-ons…", style = VortXTheme.type.label,
            modifier = Modifier.padding(horizontal = TvDimens.edge))
        LazyRow(contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap)) {
            items(section.items, key = ::searchResultItemKey) { item ->
                TvPosterCard(item = item, onClick = { onItem(item) }, onFocused = {}, menu = PosterCardMenu.CATALOG)
            }
        }
    }
}
