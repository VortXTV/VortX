package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.model.DiscoverFilters
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DiscoverViewModel

/// TV Discover: the 10-foot analogue of the phone [com.vortx.android.ui.screens.DiscoverScreen], driven by
/// the SAME [DiscoverViewModel]. The type / catalog / genre pivots are focusable chip rows; each dispatches
/// the engine's OWN `requestJson` verbatim through [DiscoverViewModel.select] (never a reconstruction), so
/// the S03-era "every chip is the same default Load" bug cannot reappear on TV either. Selecting a title
/// opens the shared [TvDetailScreen] via [onItem]. The active profile's Kids source guard applies for free,
/// because it lives inside the reused ViewModel/engine, not in this UI.
@Composable
fun TvDiscoverScreen(
    viewModel: DiscoverViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadingMore by viewModel.loadingMore.collectAsStateWithLifecycle()
    val advancedFilters by viewModel.advancedFilters.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<DiscoverResult>)?.data?.filters
    var showAdvancedFilters by remember { mutableStateOf(false) }

    // SD-8: without a Stremio or VortX sign-in there are no catalogs to pivot; show the sign-in prompt.
    if (!signedIn) {
        TvSignedOut(modifier = modifier.fillMaxSize())
        return
    }

    Column(modifier = modifier.fillMaxSize()) {
        TvDiscoverFilters(
            filters = filters,
            advancedFilterCount = advancedFilters.activeCount,
            onSelect = viewModel::select,
            onOpenAdvanced = { showAdvancedFilters = true },
            onClearAdvanced = viewModel::clearAdvancedFilters,
        )
        when (val s = state) {
            is UiState.Loading -> TvLoading()
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry)
            is UiState.Success -> {
                val shown = viewModel.filteredItems(s.data)
                if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    ) {
                        Text(
                            stringResource(R.string.discover_shown_count, shown.size),
                            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        )
                        TvFilterChip(
                            label = stringResource(R.string.discover_clear_filters),
                            selected = false,
                            onClick = viewModel::clearAdvancedFilters,
                        )
                    }
                }
                TvPosterGrid(
                    items = shown,
                    onItem = onItem,
                    emptyHint = if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                        stringResource(R.string.discover_no_matches_message)
                    } else {
                        stringResource(R.string.discover_catalog_empty)
                    },
                    footer = if (s.data.filters.hasNextPage) {
                        { TvLoadMore(loading = loadingMore, onClick = viewModel::loadMore) }
                    } else {
                        null
                    },
                )
                if (showAdvancedFilters) {
                    TvDiscoverFilterPanel(
                        filters = advancedFilters,
                        genreOptions = viewModel.advancedGenreOptions(s.data),
                        showSeasons = viewModel.showsAdvancedSeasonFilters(s.data),
                        onChange = viewModel::setAdvancedFilters,
                        onDismiss = { showAdvancedFilters = false },
                    )
                }
            }
        }
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
