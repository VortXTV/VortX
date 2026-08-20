package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.VortXApplication
import com.vortx.android.home.CollectionsHubModel
import com.vortx.android.home.CollectionsHubProviderPolicy
import com.vortx.android.model.DiscoverFilters
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import kotlinx.coroutines.launch

/// TV Discover: the 10-foot analogue of the phone [com.vortx.android.ui.screens.DiscoverScreen] and the
/// parity twin of Apple `SourcesTV/DiscoverView.swift` + `BrowseGridView`, driven by the SAME
/// [DiscoverViewModel]. Over the engine's type / catalog / genre pivots it lays a living-backdrop hero that
/// follows the focused grid tile (seeded from the first result when nothing is focused, mirroring tvOS
/// `seedIfEmpty`) and a Collections hub band above the grid. Each chip dispatches the engine's OWN
/// `requestJson` verbatim through [DiscoverViewModel.select] (never a reconstruction), so the S03-era "every
/// chip is the same default Load" bug cannot reappear on TV either.
@Composable
fun TvDiscoverScreen(
    viewModel: DiscoverViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
    // Bumped by the shell when the Discover tab is re-selected on the rail, so the browse grid scrolls back to
    // the top -- the 10-foot analogue of Apple's `scrollToTopOnBump`.
    reselectSignal: Int = 0,
) {
    // SD-8: without a Stremio or VortX sign-in there are no catalogs to pivot; show the sign-in prompt.
    if (!signedIn) {
        TvSignedOut(modifier = modifier.fillMaxSize())
        return
    }

    // Reuse the phone Collections hub model + composable (TvCollectionsHub / TvCollectionsBrowseScreen). It is
    // owned here in-composition rather than injected through the (un-owned) ViewModel factory: a plain class
    // held in `remember`, loaded once, and closed on dispose so it never leaks its prefs listener.
    val context = LocalContext.current
    val repo = remember { (context.applicationContext as? VortXApplication)?.catalogRepository }
    val collectionsHub = remember {
        CollectionsHubModel(
            context = context.applicationContext,
            tmdbCatalogSupported = {
                repo?.installedAddons()?.getOrNull()
                    ?.let(CollectionsHubProviderPolicy::supportsTmdbCatalogItems) ?: false
            },
        )
    }
    val snapshot by collectionsHub.snapshot.collectAsStateWithLifecycle()
    val browse by collectionsHub.browse.collectAsStateWithLifecycle()
    val hubScope = rememberCoroutineScope()
    LaunchedEffect(collectionsHub) { collectionsHub.load() }
    DisposableEffect(collectionsHub) { onDispose { collectionsHub.close() } }

    // A tapped Collections tile takes over the whole surface with its own category browse, exactly like the
    // Home hub does (reuses the shared TvCollectionsBrowseScreen).
    if (browse.target != null) {
        TvCollectionsBrowseScreen(
            state = browse,
            onBack = collectionsHub::closeBrowse,
            onItem = onItem,
            onCategory = { hubScope.launch { collectionsHub.selectCategory(it) } },
            onRetry = { hubScope.launch { collectionsHub.retry() } },
            onLoadMore = { hubScope.launch { collectionsHub.loadMore() } },
            modifier = modifier,
        )
        return
    }

    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadingMore by viewModel.loadingMore.collectAsStateWithLifecycle()
    val advancedFilters by viewModel.advancedFilters.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<DiscoverResult>)?.data?.filters
    var showAdvancedFilters by remember { mutableStateOf(false) }

    val successData = (state as? UiState.Success<DiscoverResult>)?.data
    val shownItems = successData?.let(viewModel::filteredItems).orEmpty()
    var focusedItem by remember(successData?.items?.firstOrNull()?.id) { mutableStateOf<MetaItem?>(null) }
    val heroItem = focusedItem ?: shownItems.firstOrNull()
    val enriched = rememberEnrichedHeroItem(heroItem)
    val heroHeight = (LocalConfiguration.current.screenHeightDp * 0.44f).dp.coerceIn(240.dp, 400.dp)

    // Re-selecting the active Discover tab scrolls the browse grid back to the top (Apple `scrollToTopOnBump`).
    // Baseline-captured on first composition so a plain tab switch (which restores the saved scroll position)
    // never force-scrolls; only a bump that happens WHILE this screen is composed scrolls. Fail-soft if the
    // grid is not attached yet.
    val discoverGridState = rememberLazyGridState()
    val initialReselect = remember { reselectSignal }
    LaunchedEffect(reselectSignal) {
        if (reselectSignal != initialReselect) runCatching { discoverGridState.animateScrollToItem(0) }
    }

    Column(modifier = modifier.fillMaxSize()) {
        TvAmbientHero(enriched, modifier = Modifier.fillMaxWidth().height(heroHeight))
        TvDiscoverFilters(
            filters = filters,
            advancedFilterCount = advancedFilters.activeCount,
            onSelect = viewModel::select,
            onOpenAdvanced = { showAdvancedFilters = true },
            onClearAdvanced = viewModel::clearAdvancedFilters,
        )
        when (val s = state) {
            is UiState.Loading -> TvLoading(Modifier.weight(1f))
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry, modifier = Modifier.weight(1f))
            is UiState.Success -> TvBrowseGrid(
                items = shownItems,
                emptyHint = if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                    stringResource(R.string.discover_no_matches_message)
                } else {
                    stringResource(R.string.discover_catalog_empty)
                },
                modifier = Modifier.fillMaxWidth().weight(1f),
                gridState = discoverGridState,
                header = if (snapshot.isVisible || advancedFilters.isActive) {
                    {
                        if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                            item(span = { GridItemSpan(maxLineSpan) }) {
                                TvDiscoverFilterSummary(shownItems.size, viewModel::clearAdvancedFilters)
                            }
                        }
                        if (snapshot.isVisible) {
                            item(span = { GridItemSpan(maxLineSpan) }) {
                                TvCollectionsHub(
                                    snapshot = snapshot,
                                    onOpen = { target -> hubScope.launch { collectionsHub.open(target) } },
                                    onRetryProviders = { hubScope.launch { collectionsHub.load() } },
                                )
                            }
                        }
                    }
                } else {
                    null
                },
                footer = if (s.data.filters.hasNextPage) {
                    { TvLoadMore(loading = loadingMore, onClick = viewModel::loadMore) }
                } else {
                    null
                },
            ) { item ->
                TvPosterCard(
                    item = item,
                    onClick = { onItem(item) },
                    onFocused = { focusedItem = item },
                    width = null,
                )
            }
        }
    }
    if (showAdvancedFilters && successData != null) {
        TvDiscoverFilterPanel(
            filters = advancedFilters,
            genreOptions = viewModel.advancedGenreOptions(successData),
            showSeasons = viewModel.showsAdvancedSeasonFilters(successData),
            onChange = viewModel::setAdvancedFilters,
            onDismiss = { showAdvancedFilters = false },
        )
    }
}

/// The active-advanced-filter summary row (result count + a Clear chip), shown as a full-span header above
/// the grid when the client advanced filters are narrowing the engine catalog.
@Composable
private fun TvDiscoverFilterSummary(shownCount: Int, onClear: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            stringResource(R.string.discover_shown_count, shownCount),
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
        )
        TvFilterChip(
            label = stringResource(R.string.discover_clear_filters),
            selected = false,
            onClick = onClear,
        )
    }
}

/// The type / catalog / genre chip rows above the grid. No-op while [filters] is null (still loading) so the
/// grid below owns the loading/error/empty state. Catalog row shows only when there is a real choice
/// (size > 1), and the genre row only when the selected catalog declares one -- the same gating as the phone
/// `DiscoverFilterChips`.
@Composable
private fun TvDiscoverFilters(
    filters: DiscoverFilters?,
    advancedFilterCount: Int,
    onSelect: (String) -> Unit,
    onOpenAdvanced: () -> Unit,
    onClearAdvanced: () -> Unit,
) {
    if (filters == null) return
    Column(
        modifier = Modifier.padding(top = TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        TvChipRow(
            buildList {
                add(
                    TvChipModel(
                        label = if (advancedFilterCount > 0) {
                            stringResource(R.string.discover_filters_count, advancedFilterCount)
                        } else {
                            stringResource(R.string.discover_filters)
                        },
                        selected = advancedFilterCount > 0,
                        value = "filters",
                    ),
                )
                if (advancedFilterCount > 0) {
                    add(TvChipModel(stringResource(R.string.discover_clear), false, "clear"))
                }
            },
            onChipClick = { if (it.value == "clear") onClearAdvanced() else onOpenAdvanced() },
        )
        if (filters.types.isNotEmpty()) {
            TvChipRow(filters.types.map { TvChipModel(it.label, it.selected, it.requestJson) }, onChipClick = { onSelect(it.value) })
        }
        if (filters.catalogs.size > 1) {
            TvChipRow(filters.catalogs.map { TvChipModel(it.label, it.selected, it.requestJson) }, onChipClick = { onSelect(it.value) })
        }
        if (filters.genres.isNotEmpty()) {
            TvChipRow(filters.genres.map { TvChipModel(it.label, it.selected, it.requestJson) }, onChipClick = { onSelect(it.value) })
        }
    }
}

/// The "Load more" control at the foot of a Discover grid that has another page (the engine appends the next
/// page to the same catalog, so [DiscoverViewModel.loadMore] needs no manual merge here). A focusable chip so
/// the D-pad can reach it after the last row.
@Composable
private fun TvLoadMore(loading: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = TvDimens.rowGap),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (loading) {
            CircularProgressIndicator(color = VortXTheme.colors.accent)
        } else {
            TvFilterChip(label = stringResource(R.string.discover_load_more), selected = false, onClick = onClick)
        }
    }
}
