package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.LibraryFilters
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.LibraryViewModel

/// TV Library: the 10-foot analogue of the phone [com.vortx.android.ui.screens.LibraryScreen], driven by the
/// SAME [LibraryViewModel]. It shows the type / sort pivots as focusable chips over the saved-title poster
/// grid; picking a title opens the shared [TvDetailScreen] via [onItem].
///
/// Per-profile is honored by construction: the LibraryViewModel derives its grid from the engine's
/// `ctx.library`, which is the ACTIVE profile's library, and re-renders live on a profile switch or an
/// add/remove -- this screen inherits all of that from the reused ViewModel with no extra code.
///
/// Slice scope: this ships browse + open. The phone grid's per-poster remove ("x") control is NOT reproduced
/// here yet (a 10-foot remove wants a focused-poster action affordance, not a touch badge) -- see the session
/// report's gap list.
@Composable
fun TvLibraryScreen(viewModel: LibraryViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<LibraryResult>)?.data?.filters

    Column(modifier = modifier.fillMaxSize()) {
        TvLibraryFilters(filters = filters, onSelect = { viewModel.load(it) })
        when (val s = state) {
            is UiState.Loading -> TvLoading()
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry)
            is UiState.Success -> TvPosterGrid(
                items = s.data.items,
                onItem = onItem,
                emptyHint = "Titles you save appear here.",
            )
        }
    }
}

/// The type / sort chip rows above the Library grid. Type row shows only when there is a real choice
/// (size > 1), matching the phone `LibraryFilterChips`. Each chip re-dispatches the engine's own
/// `requestJson` through [LibraryViewModel.load], keeping the applied filter across a later remove.
@Composable
private fun TvLibraryFilters(filters: LibraryFilters?, onSelect: (String) -> Unit) {
    if (filters == null) return
    Column(
        modifier = Modifier.padding(top = TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        if (filters.types.size > 1) {
            TvChipRow(filters.types.map { TvChipModel(it.label, it.selected, it.requestJson) }, onChipClick = { onSelect(it.value) })
        }
        if (filters.sorts.isNotEmpty()) {
            TvChipRow(filters.sorts.map { TvChipModel(it.label, it.selected, it.requestJson) }, onChipClick = { onSelect(it.value) })
        }
    }
}
