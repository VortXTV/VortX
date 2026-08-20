package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.LibraryFilters
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.LibraryViewModel

/// TV Library: the 10-foot analogue of the phone [com.vortx.android.ui.screens.LibraryScreen] and the parity
/// twin of Apple `SourcesTV/LibraryView.swift`, driven by the SAME [LibraryViewModel]. Over the saved-title
/// poster grid it lays a living-backdrop hero that follows the focused tile, a client-side type SEGMENT bar
/// (All / Movies / Shows / Anime -- the engine has no anime type, so it is derived per title), an
/// applicable-only SMART FILTER bar (Unwatched / In Progress / Watched / Short), the engine's own sort
/// chips, and a per-poster long-press menu (Mark Watched/Unwatched, Remove from Library).
///
/// Per-profile is honored by construction: the LibraryViewModel derives its grid from the engine's
/// `ctx.library` (the ACTIVE profile's library) and re-renders live on a profile switch or an add/remove.
/// The segment/smart controls are pure client refinements over the already-loaded set (no extra round-trip),
/// exactly as tvOS segments the whole library client-side.
@Composable
fun TvLibraryScreen(viewModel: LibraryViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize()) {
        when (val s = state) {
            is UiState.Loading -> TvLoading()
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry)
            is UiState.Success -> TvLibraryContent(
                result = s.data,
                onItem = onItem,
                onSelectSort = viewModel::load,
                onRemove = viewModel::remove,
                onMarkWatched = viewModel::markWatched,
            )
        }
    }
}

@Composable
private fun TvLibraryContent(
    result: LibraryResult,
    onItem: (MetaItem) -> Unit,
    onSelectSort: (String) -> Unit,
    onRemove: (String) -> Unit,
    onMarkWatched: (MetaItem, Boolean) -> Unit,
) {
    val allItems = result.items
    if (allItems.isEmpty()) {
        TvEmpty(stringResource(com.vortx.android.R.string.library_empty))
        return
    }

    // Client-side type segmentation (adds the Anime bucket the engine cannot express) + smart filters, both
    // pure refinements over the loaded set -- see TvLibrarySmartFilters.kt.
    val segments = remember(allItems) { LibrarySegment.availableSegments(allItems) }
    var segment by remember(allItems) { mutableStateOf(LibrarySegment.ALL) }
    val activeSegment = if (segment in segments || segments.isEmpty()) segment else LibrarySegment.ALL
    val afterSegment = remember(allItems, activeSegment) { activeSegment.filter(allItems) }

    val applicableFilters = remember(afterSegment) { LibrarySmartFilter.applicable(afterSegment) }
    var smartSelected by remember(allItems) { mutableStateOf(emptySet<LibrarySmartFilter>()) }
    // Only keep selected filters that still partition the current set, so a filter left over from another
    // segment can never blank the grid.
    val activeFilters = smartSelected intersect applicableFilters.toSet()
    val shown = remember(afterSegment, activeFilters) { LibrarySmartFilter.apply(afterSegment, activeFilters) }

    var focusedItem by remember(allItems) { mutableStateOf<MetaItem?>(null) }
    val heroItem = focusedItem ?: shown.firstOrNull() ?: allItems.firstOrNull()
    val enriched = rememberEnrichedHeroItem(heroItem)
    val heroHeight = (LocalConfiguration.current.screenHeightDp * 0.44f).dp.coerceIn(240.dp, 400.dp)

    Column(modifier = Modifier.fillMaxSize()) {
        TvAmbientHero(enriched, modifier = Modifier.fillMaxWidth().height(heroHeight))
        TvLibraryControls(
            filters = result.filters,
            segments = segments,
            activeSegment = activeSegment,
            onSelectSegment = { segment = it },
            applicableFilters = applicableFilters,
            selectedFilters = activeFilters,
            onToggleFilter = { smartSelected = LibrarySmartFilter.toggle(smartSelected, it) },
            onSelectSort = onSelectSort,
        )
        TvBrowseGrid(
            items = shown,
            emptyHint = stringResource(com.vortx.android.R.string.library_no_matches),
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) { item ->
            TvLibraryPosterCard(
                item = item,
                onClick = { onItem(item) },
                onFocused = { focusedItem = item },
                onRemove = { onRemove(item.id) },
                onMarkWatched = { isWatched -> onMarkWatched(item, isWatched) },
            )
        }
    }
}

/// The Library control stack: the engine sort chips over the client SEGMENT bar over the applicable SMART
/// FILTER bar. The engine's own type chips are intentionally dropped in favor of the client segment bar,
/// which covers the same movie/series split AND adds Anime (mirrors Apple's `LibrarySegment` bar). Sort
/// re-dispatches the engine's own `requestJson` verbatim.
@Composable
private fun TvLibraryControls(
    filters: LibraryFilters,
    segments: List<LibrarySegment>,
    activeSegment: LibrarySegment,
    onSelectSegment: (LibrarySegment) -> Unit,
    applicableFilters: List<LibrarySmartFilter>,
    selectedFilters: Set<LibrarySmartFilter>,
    onToggleFilter: (LibrarySmartFilter) -> Unit,
    onSelectSort: (String) -> Unit,
) {
    Column(
        modifier = Modifier.padding(top = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        if (filters.sorts.isNotEmpty()) {
            TvChipRow(
                filters.sorts.map { TvChipModel(it.label, it.selected, it.requestJson) },
                onChipClick = { onSelectSort(it.value) },
            )
        }
        if (segments.isNotEmpty()) {
            TvChipRow(
                segments.map {
                    TvChipModel(stringResource(it.titleResource), it == activeSegment, it.name)
                },
                onChipClick = { chip ->
                    segments.firstOrNull { it.name == chip.value }?.let(onSelectSegment)
                },
            )
        }
        if (applicableFilters.isNotEmpty()) {
            TvChipRow(
                applicableFilters.map {
                    TvChipModel(stringResource(it.titleResource), it in selectedFilters, it.name)
                },
                onChipClick = { chip ->
                    applicableFilters.firstOrNull { it.name == chip.value }?.let(onToggleFilter)
                },
            )
        }
    }
}
