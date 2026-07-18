package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
fun TvDiscoverScreen(viewModel: DiscoverViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadingMore by viewModel.loadingMore.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<DiscoverResult>)?.data?.filters

    Column(modifier = modifier.fillMaxSize()) {
        TvDiscoverFilters(filters = filters, onSelect = viewModel::select)
        when (val s = state) {
            is UiState.Loading -> TvLoading()
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry)
            is UiState.Success -> TvPosterGrid(
                items = s.data.items,
                onItem = onItem,
                emptyHint = "No titles in this catalog yet.",
                footer = if (s.data.filters.hasNextPage) {
                    { TvLoadMore(loading = loadingMore, onClick = viewModel::loadMore) }
                } else {
                    null
                },
            )
        }
    }
}

/// The type / catalog / genre chip rows above the grid. No-op while [filters] is null (still loading) so the
/// grid below owns the loading/error/empty state. Catalog row shows only when there is a real choice
/// (size > 1), and the genre row only when the selected catalog declares one -- the same gating as the phone
/// `DiscoverFilterChips`.
@Composable
private fun TvDiscoverFilters(filters: DiscoverFilters?, onSelect: (String) -> Unit) {
    if (filters == null) return
    Column(
        modifier = Modifier.padding(top = TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
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
            TvFilterChip(label = "Load more", selected = false, onClick = onClick)
        }
    }
}
