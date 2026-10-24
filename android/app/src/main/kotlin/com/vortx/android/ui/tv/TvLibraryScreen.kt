package com.vortx.android.ui.tv

import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.LibraryFilters
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.library.LibrarySegment
import com.vortx.android.ui.library.LibrarySmartFilter
import com.vortx.android.ui.UiState
import com.vortx.android.ui.randompick.RandomLibraryPickHeader
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.LibraryLandingViewModel
import com.vortx.android.ui.viewmodel.LibraryLandingResult

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
fun TvLibraryScreen(
    viewModel: LibraryViewModel,
    landingViewModel: LibraryLandingViewModel,
    onItem: (MetaItem) -> Unit,
    onDownloads: () -> Unit,
    onWatchlist: () -> Unit,
    onPreviouslyWatched: () -> Unit,
    modifier: Modifier = Modifier,
    entryFocusRequesters: Map<TvLibraryRoute, FocusRequester> = emptyMap(),
    onSmartCollections: (() -> Unit)? = null,
    onNetworkShares: (() -> Unit)? = null,
    onDirectResume: (MetaItem) -> Unit = onItem,
    pickerActive: Boolean = true,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val landingState by landingViewModel.state.collectAsStateWithLifecycle()
    val randomPick by viewModel.randomPickState.collectAsStateWithLifecycle()
    val pickerIsActive by rememberUpdatedState(pickerActive)
    DisposableEffect(viewModel, pickerActive) {
        if (!pickerActive) viewModel.clearRandomPick()
        onDispose { viewModel.clearRandomPick() }
    }
    val randomPickHeader: @Composable () -> Unit = {
        RandomLibraryPickHeader(
            state = randomPick,
            onPick = { filter -> if (pickerIsActive) viewModel.pickRandom(filter) },
            onOpen = {
                if (pickerIsActive) viewModel.randomPickForAction { item -> if (pickerIsActive) onItem(item) }
            },
            onPlay = {
                if (pickerIsActive) viewModel.randomPickForAction { item -> if (pickerIsActive) onDirectResume(item) }
            },
            modifier = Modifier.fillMaxWidth(),
            tv = true,
        )
    }

    Column(modifier = modifier.fillMaxSize()) {
        if (state !is UiState.Success) {
            TvLibraryEntries(onDownloads, onWatchlist, onPreviouslyWatched, entryFocusRequesters, onSmartCollections, onNetworkShares)
            randomPickHeader()
        }
        when (val s = state) {
            is UiState.Loading -> TvLoading()
            is UiState.Error -> TvError(s.message, onRetry = viewModel::retry)
            is UiState.Success -> TvLibraryContent(
                result = s.data,
                onItem = onItem,
                onSelectSort = viewModel::load,
                onRemove = viewModel::remove,
                onMarkWatched = viewModel::markWatched,
                landingState = landingState,
                onRetryLanding = landingViewModel::retry,
                onRemoveContinueWatching = landingViewModel::removeFromContinueWatching,
                onDownloads = onDownloads,
                onWatchlist = onWatchlist,
                onPreviouslyWatched = onPreviouslyWatched,
                onSmartCollections = onSmartCollections,
                entryFocusRequesters = entryFocusRequesters,
                onNetworkShares = onNetworkShares,
                randomPickHeader = randomPickHeader,
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
    landingState: UiState<LibraryLandingResult>,
    onRetryLanding: () -> Unit,
    onRemoveContinueWatching: (MetaItem) -> Unit,
    onDownloads: () -> Unit,
    onWatchlist: () -> Unit,
    onPreviouslyWatched: () -> Unit,
    entryFocusRequesters: Map<TvLibraryRoute, FocusRequester>,
    randomPickHeader: @Composable () -> Unit,
    onSmartCollections: (() -> Unit)? = null,
    onNetworkShares: (() -> Unit)? = null,
) {
    val allItems = result.items

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

    // One vertical owner lets the landing entries, resume rail, living hero and saved grid remain reachable
    // on shorter TV viewports. The saved-title hero and controls are retained as full-width grid sections.
    TvBrowseGrid(
        items = shown,
        emptyHint = stringResource(com.vortx.android.R.string.library_no_matches),
        modifier = Modifier.fillMaxSize(),
        header = {
            item(key = "library-entries", span = { GridItemSpan(maxLineSpan) }) {
                TvLibraryEntries(onDownloads, onWatchlist, onPreviouslyWatched, entryFocusRequesters, onSmartCollections, onNetworkShares)
            }
            when (val landing = landingState) {
                is UiState.Loading -> Unit
                is UiState.Error -> item(key = "library-landing-error", span = { GridItemSpan(maxLineSpan) }) {
                    TvError(landing.message, onRetryLanding)
                }
                is UiState.Success -> if (landing.data.continueWatching.isNotEmpty()) {
                    item(key = "library-continue-watching", span = { GridItemSpan(maxLineSpan) }) {
                        TvContinueWatchingRail(landing.data.continueWatching, onItem, onRemoveContinueWatching)
                    }
                }
            }
            if (heroItem != null) item(key = "library-hero", span = { GridItemSpan(maxLineSpan) }) {
                TvAmbientHero(enriched, modifier = Modifier.fillMaxWidth().height(heroHeight))
            }
            item(key = "library-controls", span = { GridItemSpan(maxLineSpan) }) {
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
            }
            item(key = "library-random-pick", span = { GridItemSpan(maxLineSpan) }) {
                randomPickHeader()
            }
            if (shown.isEmpty()) item(key = "library-empty", span = { GridItemSpan(maxLineSpan) }) {
                Text(
                    stringResource(if (allItems.isEmpty()) com.vortx.android.R.string.library_empty else com.vortx.android.R.string.library_no_matches),
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        },
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

@Composable
private fun TvLibraryEntries(
    onDownloads: () -> Unit,
    onWatchlist: () -> Unit,
    onHistory: () -> Unit,
    focusRequesters: Map<TvLibraryRoute, FocusRequester>,
    onSmartCollections: (() -> Unit)? = null,
    onNetworkShares: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        fun focusModifier(route: TvLibraryRoute): Modifier = focusRequesters[route]?.let { Modifier.focusRequester(it) } ?: Modifier
        TvLibraryEntry("Downloads", "Offline", VortXIcons.download, onDownloads, Modifier.weight(1f).then(focusModifier(TvLibraryRoute.DOWNLOADS)))
        TvLibraryEntry("Watchlist", "Plan to watch", VortXIcons.starFill, onWatchlist, Modifier.weight(1f).then(focusModifier(TvLibraryRoute.WATCHLIST)))
        TvLibraryEntry("History", "Previously watched", VortXIcons.clock, onHistory, Modifier.weight(1f).then(focusModifier(TvLibraryRoute.HISTORY)))
        onSmartCollections?.let {
            TvLibraryEntry(androidx.compose.ui.res.stringResource(com.vortx.android.R.string.smart_collections_title),
                androidx.compose.ui.res.stringResource(com.vortx.android.R.string.smart_collections_library_subtitle),
                androidx.compose.material.icons.Icons.Filled.FilterList, it,
                Modifier.weight(1f).then(focusModifier(TvLibraryRoute.SMART_COLLECTIONS)))
        }
        onNetworkShares?.let {
            TvLibraryEntry("Network shares", "NAS and computers", androidx.compose.material.icons.Icons.Filled.Storage, it,
                Modifier.weight(1f).then(focusModifier(TvLibraryRoute.NETWORK_SHARES)))
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvLibraryEntry(title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
        colors = ClickableSurfaceDefaults.colors(containerColor = colors.surface1.copy(alpha = 0.88f), focusedContainerColor = colors.surface3),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.025f),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.dp, colors.hairline), shape = VortXShapes.card),
            focusedBorder = Border(BorderStroke(TvDimens.focusBorder, colors.accentBright), shape = VortXShapes.card),
        ),
    ) {
        Row(modifier = Modifier.padding(VortXTheme.spacing.md), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Icon(icon, contentDescription = null, tint = colors.accentBright)
            Column {
                Text(title, style = VortXTheme.type.cardTitle)
                Text(subtitle, style = VortXTheme.type.label.copy(color = colors.textSecondary))
            }
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
