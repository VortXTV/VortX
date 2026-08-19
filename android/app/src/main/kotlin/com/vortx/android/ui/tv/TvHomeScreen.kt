package com.vortx.android.ui.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed as gridItemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.home.HomeCatalogLayout
import com.vortx.android.home.HomeCatalogLayoutPolicy
import com.vortx.android.home.HomeCatalogPresentation
import com.vortx.android.home.HomeRail
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.TOP_PICKS_CATALOG_ID
import com.vortx.android.home.SIMKL_WATCHLIST_CATALOG_ID
import com.vortx.android.home.TRAKT_WATCHLIST_CATALOG_ID
import com.vortx.android.home.UPCOMING_EPISODES_CATALOG_ID
import com.vortx.android.home.UPCOMING_MOVIES_CATALOG_ID
import com.vortx.android.ui.UiState
import com.vortx.android.ui.homeCatalogItemKey
import com.vortx.android.ui.normalizeHomeCatalogs
import com.vortx.android.ui.normalizeHomeItems
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.VortXApplication
import com.vortx.android.player.warm.SourceWarmer
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.posterMenuFor
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first

/// The TV Home browse wall: a cinematic hero band that follows the focused tile, over D-pad-focus poster
/// rows. Driven by the SAME [HomeViewModel] the phone Home uses (it collects the engine's continuous
/// `homeUpdates` stream), so Continue Watching + every add-on catalog rail arrive from one data path -- this
/// screen only changes the presentation to a 10-foot, focus-first layout. Loading/error are first-class
/// states, never a bare black screen.
@Composable
fun TvHomeScreen(viewModel: HomeViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val contentOwnerGeneration by viewModel.contentOwnerGeneration.collectAsStateWithLifecycle()
    val catalogLayout by viewModel.homeCatalogLayout.collectAsStateWithLifecycle()
    val collections by viewModel.collections.collectAsStateWithLifecycle()
    val collectionBrowse by viewModel.collectionBrowse.collectAsStateWithLifecycle()
    if (collectionBrowse.target != null) {
        TvCollectionsBrowseScreen(
            state = collectionBrowse,
            onBack = viewModel::closeCollection,
            onItem = onItem,
            onCategory = viewModel::selectCollectionCategory,
            onRetry = viewModel::retryCollection,
            onLoadMore = viewModel::loadMoreCollection,
            modifier = modifier,
        )
        return
    }
    when (val s = state) {
        is UiState.Loading -> TvLoading(modifier)
        is UiState.Error -> TvError(s.message, onRetry = viewModel::load, modifier = modifier)
        is UiState.Success ->
            if (s.data.isEmpty()) {
                TvError(
                    "No Home rows are visible. Turn rows back on in Settings > Appearance > Customize Home.",
                    onRetry = viewModel::load,
                    modifier = modifier,
                )
            } else {
                TvHomeContent(
                    catalogs = s.data,
                    contentOwnerGeneration = contentOwnerGeneration,
                    catalogLayout = catalogLayout,
                    collections = collections,
                    onCollection = viewModel::openCollection,
                    onRetryCollections = viewModel::retryCollectionsHub,
                    onItem = onItem,
                    onRemoveFromContinueWatching = viewModel::removeFromContinueWatching,
                    onLoadRowPage = viewModel::loadNextPage,
                    onLoadMoreRows = viewModel::loadMoreRows,
                    modifier = modifier,
                )
            }
    }
}

@Composable
private fun TvHomeContent(
    catalogs: List<Catalog>,
    contentOwnerGeneration: Long,
    catalogLayout: HomeCatalogLayout,
    collections: CollectionsHubSnapshot,
    onCollection: (CollectionsHubTarget) -> Unit,
    onRetryCollections: () -> Unit,
    onItem: (MetaItem) -> Unit,
    onRemoveFromContinueWatching: (MetaItem) -> Unit,
    onLoadRowPage: (Catalog) -> Unit,
    onLoadMoreRows: () -> Unit,
    modifier: Modifier,
) {
    val colors = VortXTheme.colors
    val visibleCatalogs = remember(catalogs) { tvHomeCatalogs(catalogs) }
    // The coordinator tracks the actual composed node, including its row. A title duplicated in another
    // rail therefore cannot masquerade as the tile whose focus node was removed. Owner generation and
    // layout are state keys, so neither an old owner's focused hero nor a rail-only recovery lease can
    // cross into the replacement owner's poster wall.
    var focusState by remember(contentOwnerGeneration, catalogLayout) {
        mutableStateOf(initialTvHomeFocusState(visibleCatalogs))
    }
    var focusGeneration by remember(contentOwnerGeneration, catalogLayout) { mutableStateOf(0L) }
    var focusRecovery by remember(contentOwnerGeneration, catalogLayout) {
        mutableStateOf<TvHomeFocusRecoveryLease?>(null)
    }
    var hasReceivedFocus by remember(contentOwnerGeneration, catalogLayout) { mutableStateOf(false) }
    val heroItem = focusState.focusedItem()
        ?: visibleCatalogs.firstNotNullOfOrNull { it.items.firstOrNull() }

    // Seed D-pad focus on the first tile of the first row so a fresh TV entry lands somewhere actionable
    // instead of nowhere (a TV has no touch to bootstrap focus). Guarded: requestFocus throws if the node
    // is not attached yet, so it runs after a frame and swallows the race.
    val firstCardFocus = remember(contentOwnerGeneration, catalogLayout) { FocusRequester() }
    val recoveryFocus = remember(contentOwnerGeneration, catalogLayout) { FocusRequester() }
    val columnState = rememberLazyListState()
    val rowStates = remember(contentOwnerGeneration, catalogLayout) {
        mutableStateMapOf<String, LazyListState>()
    }

    val heroHeight = (LocalConfiguration.current.screenHeightDp * 0.5f).dp.coerceIn(280.dp, 460.dp)
    fun acceptFocus(rowId: String, item: MetaItem) {
        hasReceivedFocus = true
        focusGeneration += 1L
        focusRecovery = null
        focusState = focusState.withFocused(rowId, item)
    }

    Column(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        // Hook site: the living-backdrop cinematic hero (backdrop crossfade + Ken Burns + ambient trailer +
        // metadata overlay) lives in TvAmbientHero.kt. It follows the same focus-driven `heroItem`.
        TvAmbientHero(heroItem, modifier = Modifier.fillMaxWidth().height(heroHeight))
        if (catalogLayout == HomeCatalogLayout.WALL) {
            TvCatalogWall(
                catalogs = visibleCatalogs,
                onItem = onItem,
                onFocused = ::acceptFocus,
                onRemoveFromContinueWatching = onRemoveFromContinueWatching,
                onLoadRowPage = onLoadRowPage,
                onLoadMoreRows = onLoadMoreRows,
                firstCardFocus = firstCardFocus,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f),
                state = columnState,
                contentPadding = PaddingValues(top = TvDimens.rowGap, bottom = TvDimens.edge),
                verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
            ) {
                if (collections.isVisible) {
                    item(key = "vortx.home.collectionsHub") {
                        TvCollectionsHub(collections, onCollection, onRetryCollections, firstCardFocus)
                    }
                }
                itemsIndexed(visibleCatalogs, key = { _, c -> c.id }) { index, catalog ->
                    if (index == visibleCatalogs.lastIndex) {
                        LaunchedEffect(visibleCatalogs.size, catalog.id) { onLoadMoreRows() }
                    }
                    TvCatalogRow(
                        catalog = catalog,
                        onItem = onItem,
                        onFocused = { acceptFocus(catalog.id, it) },
                        onRemoveFromContinueWatching = onRemoveFromContinueWatching,
                        onEndReached = if (catalog.hasNextPage) {
                            { onLoadRowPage(catalog) }
                        } else {
                            null
                        },
                        firstCardFocus = if (index == 0 && !collections.isVisible) firstCardFocus else null,
                        recovery = focusRecovery?.recovery,
                        recoveryFocus = recoveryFocus,
                        onRowState = { rowId, state -> rowStates[rowId] = state },
                        onRowDisposed = { rowId, state ->
                            if (rowStates[rowId] === state) rowStates.remove(rowId)
                        },
                    )
                }
            }
        }
    }

    LaunchedEffect(contentOwnerGeneration, catalogLayout) {
        delay(120)
        if (!hasReceivedFocus) runCatching { firstCardFocus.requestFocus() }
    }

    LaunchedEffect(visibleCatalogs, contentOwnerGeneration, catalogLayout) {
        val reconciled = reconcileTvHomeFocus(focusState, visibleCatalogs)
        focusState = reconciled.state
        focusGeneration += 1L
        val generation = focusGeneration
        focusRecovery = if (catalogLayout == HomeCatalogLayout.RAILS) {
            reconciled.recovery?.let { TvHomeFocusRecoveryLease(it, generation) }
        } else {
            null
        }
    }

    LaunchedEffect(focusRecovery, focusGeneration) {
        val lease = focusRecovery ?: return@LaunchedEffect
        val target = lease.recovery
        // The focused row/item may be far outside both lazy viewports. Compose the row first, then the
        // horizontal item, wait one frame for its modifier node, and only then request focus.
        columnState.scrollToItem(target.rowIndex)
        val rowState = snapshotFlow { rowStates[target.key.rowId] }.filterNotNull().first()
        rowState.scrollToItem(target.itemIndex)
        withFrameNanos { }
        // A user D-pad move can land during either scroll or the frame wait. Re-check the exact pending
        // request, generation, and logical focus owner immediately before the side effect.
        if (!lease.stillOwns(focusRecovery, focusGeneration, focusState.focused)) return@LaunchedEffect
        runCatching { recoveryFocus.requestFocus() }
        if (lease.stillOwns(focusRecovery, focusGeneration, focusState.focused)) focusRecovery = null
    }
}

/// One titled focus row: the editorial header (Continue Watching gets the "Pick up where you left off"
/// kicker, like tvOS) over a horizontally-scrolling [LazyRow] of [TvPosterCard]s. The D-pad moves focus
/// left/right within the row and up/down between rows; the focused tile drives the hero via [onFocused].
@Composable
private fun TvCatalogRow(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    onFocused: (MetaItem) -> Unit,
    onRemoveFromContinueWatching: (MetaItem) -> Unit,
    onEndReached: (() -> Unit)?,
    firstCardFocus: FocusRequester?,
    recovery: TvHomeFocusRecovery?,
    recoveryFocus: FocusRequester?,
    onRowState: (String, LazyListState) -> Unit = { _, _ -> },
    onRowDisposed: (String, LazyListState) -> Unit = { _, _ -> },
) {
    val visibleItems = remember(catalog.items) { tvHomeItems(catalog.items) }
    val rowState = rememberLazyListState()
    DisposableEffect(catalog.id, rowState) {
        onRowState(catalog.id, rowState)
        onDispose { onRowDisposed(catalog.id, rowState) }
    }

    // WARM-THE-PICK-ON-FOCUS for the Continue Watching row: after ~500 ms of dwell on a focused CW card,
    // resolve + rank its winning source and warm the direct connection so pressing play starts faster.
    // The 500 ms delay is the dwell (arrowing quickly past cards never warms), and re-assigning the focused
    // item cancels the prior dwell (only the settled card warms). Movie-only + direct/HTTP-only + never
    // debrid is enforced inside [SourceWarmer]. Fail-soft: a missed warm just falls back to the tap search.
    val warmContext = LocalContext.current
    val isContinueWatchingRow = remember(catalog) { posterMenuFor(catalog) == PosterCardMenu.CONTINUE_WATCHING }
    var focusedCwItem by remember { mutableStateOf<MetaItem?>(null) }
    LaunchedEffect(focusedCwItem) {
        val item = focusedCwItem ?: return@LaunchedEffect
        if (!isContinueWatchingRow) return@LaunchedEffect
        delay(500)
        val repo = (warmContext.applicationContext as? VortXApplication)?.catalogRepository ?: return@LaunchedEffect
        SourceWarmer.warmForContinueWatching(warmContext, repo, item.type, item.id)
    }

    Column(modifier = Modifier.focusGroup()) {
        TvCatalogHeader(catalog)
        LazyRow(
            state = rowState,
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            itemsIndexed(visibleItems, key = { _, it -> tvHomeItemKey(it) }) { i, item ->
                if (onEndReached != null && i == visibleItems.lastIndex) {
                    LaunchedEffect(catalog.engineIndex, visibleItems.size, tvHomeItemKey(item)) {
                        onEndReached()
                    }
                }
                val menu = posterMenuFor(catalog)
                val focusKey = TvHomeFocusKey(catalog.id, item.type, item.id)
                TvPosterCard(
                    item = item,
                    onClick = { onItem(item) },
                    onFocused = {
                        onFocused(item)
                        if (menu == PosterCardMenu.CONTINUE_WATCHING) focusedCwItem = item
                    },
                    focusRequester = when {
                        recovery?.key == focusKey -> recoveryFocus
                        firstCardFocus != null && i == 0 -> firstCardFocus
                        else -> null
                    },
                    menu = menu,
                    onDetails = if (menu == PosterCardMenu.CONTINUE_WATCHING) ({ onItem(item) }) else null,
                    onRemoveFromContinueWatching = if (menu == PosterCardMenu.CONTINUE_WATCHING) {
                        { onRemoveFromContinueWatching(item) }
                    } else {
                        null
                    },
                )
            }
        }
    }
}

@Composable
private fun TvCatalogWall(
    catalogs: List<Catalog>,
    onItem: (MetaItem) -> Unit,
    onFocused: (String, MetaItem) -> Unit,
    onRemoveFromContinueWatching: (MetaItem) -> Unit,
    onLoadRowPage: (Catalog) -> Unit,
    onLoadMoreRows: () -> Unit,
    firstCardFocus: FocusRequester,
    modifier: Modifier,
) {
    val firstAction = remember(catalogs) {
        catalogs.firstNotNullOfOrNull { catalog ->
            tvHomeItems(catalog.items).firstOrNull()?.let { catalog.id to tvHomeItemKey(it) }
        }
    }
    LazyVerticalGrid(
        columns = GridCells.Adaptive(TvDimens.posterWidth),
        modifier = modifier.focusGroup(),
        contentPadding = PaddingValues(
            start = TvDimens.edge,
            top = TvDimens.rowGap,
            end = TvDimens.edge,
            bottom = TvDimens.edge,
        ),
        horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
    ) {
        catalogs.forEachIndexed { catalogIndex, catalog ->
            when (HomeCatalogLayoutPolicy.presentation(catalog, HomeCatalogLayout.WALL)) {
                HomeCatalogPresentation.RAIL -> item(
                    key = "rail|${catalog.id}",
                    span = { GridItemSpan(maxLineSpan) },
                ) {
                    if (catalogIndex == catalogs.lastIndex) {
                        LaunchedEffect(catalogs.size, catalog.id) { onLoadMoreRows() }
                    }
                    TvCatalogRow(
                        catalog = catalog,
                        onItem = onItem,
                        onFocused = { onFocused(catalog.id, it) },
                        onRemoveFromContinueWatching = onRemoveFromContinueWatching,
                        onEndReached = if (catalog.hasNextPage) {
                            { onLoadRowPage(catalog) }
                        } else {
                            null
                        },
                        firstCardFocus = if (firstAction?.first == catalog.id) firstCardFocus else null,
                        recovery = null,
                        recoveryFocus = null,
                    )
                }

                HomeCatalogPresentation.WALL -> {
                    item(
                        key = "header|${catalog.id}",
                        span = { GridItemSpan(maxLineSpan) },
                    ) {
                        if (catalogIndex == catalogs.lastIndex) {
                            LaunchedEffect(catalogs.size, catalog.id) { onLoadMoreRows() }
                        }
                        TvCatalogHeader(catalog, edgePadding = false)
                    }
                    val visibleItems = tvHomeItems(catalog.items)
                    gridItemsIndexed(
                        items = visibleItems,
                        key = { _, item -> "wall|${catalog.id}|${tvHomeItemKey(item)}" },
                    ) { itemIndex, item ->
                        if (catalog.hasNextPage && itemIndex == visibleItems.lastIndex) {
                            LaunchedEffect(catalog.engineIndex, visibleItems.size, tvHomeItemKey(item)) {
                                onLoadRowPage(catalog)
                            }
                        }
                        val ownsFirstFocus = firstAction == (catalog.id to tvHomeItemKey(item))
                        val menu = posterMenuFor(catalog)
                        TvPosterCard(
                            item = item,
                            onClick = { onItem(item) },
                            onFocused = { onFocused(catalog.id, item) },
                            focusRequester = if (ownsFirstFocus) firstCardFocus else null,
                            menu = menu,
                            onDetails = if (menu == PosterCardMenu.CONTINUE_WATCHING) ({ onItem(item) }) else null,
                            onRemoveFromContinueWatching = if (menu == PosterCardMenu.CONTINUE_WATCHING) {
                                { onRemoveFromContinueWatching(item) }
                            } else {
                                null
                            },
                            width = null,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TvCatalogHeader(catalog: Catalog, edgePadding: Boolean = true) {
    val eyebrow = if (catalog.id == HomeRail.CONTINUE_CATALOG_ID) {
        "Pick up where you left off"
    } else when (HomeRail.forCatalog(catalog)) {
        HomeRail.TOP_PICKS -> "Based on what you watch"
        HomeRail.UPCOMING_EPISODES, HomeRail.UPCOMING_MOVIES -> "Coming soon"
        HomeRail.TRAKT_WATCHLIST -> "From Trakt"
        HomeRail.SIMKL_WATCHLIST -> "From SIMKL"
        else -> null
    }
    Column(
        modifier = Modifier.padding(
            start = if (edgePadding) TvDimens.edge else 0.dp,
            bottom = VortXTheme.spacing.sm,
        ),
    ) {
        if (eyebrow != null) {
            Text(text = eyebrow.uppercase(), style = VortXTheme.type.eyebrow)
        }
        Text(text = catalog.title, style = VortXTheme.type.sectionTitle)
    }
}

/**
 * A [Catalog.id] is the engine's stable add-on-qualified row identity (`base|type|catalog`), so two
 * rows with the same id are the same logical rail. Keep the first engine-ranked occurrence and retain
 * rows from different add-ons even when their bare manifest catalog names match.
 */
internal fun tvHomeCatalogs(catalogs: List<Catalog>): List<Catalog> =
    normalizeHomeCatalogs(catalogs)

/**
 * A content identity is type plus id: a movie and series may legitimately share an external id, while
 * two entries with the same type/id in one rail are the same title repeated by an add-on or page edge.
 */
internal fun tvHomeItems(items: List<MetaItem>): List<MetaItem> =
    normalizeHomeItems(items)

internal fun tvHomeItemKey(item: MetaItem): String = homeCatalogItemKey(item)

/** Row is part of focus identity: the same title in another rail is a different composed focus node. */
internal data class TvHomeFocusKey(
    val rowId: String,
    val type: com.vortx.android.model.MediaType,
    val itemId: String,
)

internal data class TvHomeFocusState(
    val catalogs: List<Catalog>,
    val focused: TvHomeFocusKey?,
)

/** Exact composed destination. The composable consumes it in row-scroll, item-scroll, focus order. */
internal data class TvHomeFocusRecovery(
    val key: TvHomeFocusKey,
    val rowIndex: Int,
    val itemIndex: Int,
)

/** Generation-owned pending request. A later focus event or reconciliation makes this lease stale. */
internal data class TvHomeFocusRecoveryLease(
    val recovery: TvHomeFocusRecovery,
    val generation: Long,
) {
    fun stillOwns(
        pending: TvHomeFocusRecoveryLease?,
        currentGeneration: Long,
        focused: TvHomeFocusKey?,
    ): Boolean = pending == this && currentGeneration == generation && focused == recovery.key
}

internal data class TvHomeFocusReconciliation(
    val state: TvHomeFocusState,
    val recovery: TvHomeFocusRecovery?,
)

internal fun initialTvHomeFocusState(catalogs: List<Catalog>): TvHomeFocusState = TvHomeFocusState(
    catalogs = catalogs,
    focused = catalogs.firstNotNullOfOrNull { row ->
        tvHomeItems(row.items).firstOrNull()?.let { item -> TvHomeFocusKey(row.id, item.type, item.id) }
    },
)

internal fun TvHomeFocusState.withFocused(rowId: String, item: MetaItem): TvHomeFocusState = copy(
    focused = TvHomeFocusKey(rowId, item.type, item.id),
)

// Retained hero-identity helpers. The live TV hero is driven by the focus coordinator above
// ([focusState] / [reconcileTvHomeFocus]); these pure owner-generation selection helpers are kept for
// the Home hero-identity contract test and share [tvHomeItemKey] with the rest of the screen.
internal data class TvHomeHeroState(
    val contentOwnerGeneration: Long,
    val focusedKey: String?,
)

internal data class TvHomeHeroSelection(
    val state: TvHomeHeroState,
    val item: MetaItem?,
)

internal fun tvHomeHeroSelection(
    previous: TvHomeHeroState,
    contentOwnerGeneration: Long,
    catalogs: List<Catalog>,
): TvHomeHeroSelection {
    val focusedKey = previous.focusedKey.takeIf {
        previous.contentOwnerGeneration == contentOwnerGeneration
    }
    val retained = focusedKey?.let { key ->
        catalogs.asSequence()
            .flatMap { it.items.asSequence() }
            .firstOrNull { tvHomeItemKey(it) == key }
    }
    val selected = retained ?: catalogs.firstNotNullOfOrNull { it.items.firstOrNull() }
    return TvHomeHeroSelection(
        state = TvHomeHeroState(contentOwnerGeneration, retained?.let(::tvHomeItemKey)),
        item = selected,
    )
}

internal fun TvHomeFocusState.focusedItem(): MetaItem? {
    val key = focused ?: return null
    return catalogs.firstOrNull { it.id == key.rowId }
        ?.items
        ?.firstOrNull { it.type == key.type && it.id == key.itemId }
}

/**
 * Reconcile focus against a new composed Home tree. A removed tile chooses the item that slid into its
 * old column (or the previous item when it was last). If its row vanished, the adjacent composed row at
 * the old row index wins, with the column clamped. Returning concrete indices lets the composable bring a
 * far-off destination into composition before asking its [FocusRequester] for focus.
 */
internal fun reconcileTvHomeFocus(
    previous: TvHomeFocusState,
    catalogs: List<Catalog>,
): TvHomeFocusReconciliation {
    val focused = previous.focused
    if (focused == null) {
        return TvHomeFocusReconciliation(initialTvHomeFocusState(catalogs), recovery = null)
    }

    val survivingRowIndex = catalogs.indexOfFirst { it.id == focused.rowId }
    if (survivingRowIndex >= 0) {
        val survivingItems = tvHomeItems(catalogs[survivingRowIndex].items)
        if (survivingItems.any { it.type == focused.type && it.id == focused.itemId }) {
            return TvHomeFocusReconciliation(previous.copy(catalogs = catalogs), recovery = null)
        }
    }

    val oldRowIndex = previous.catalogs.indexOfFirst { it.id == focused.rowId }.coerceAtLeast(0)
    val oldItems = previous.catalogs.getOrNull(oldRowIndex)?.items?.let(::tvHomeItems).orEmpty()
    val oldItemIndex = oldItems.indexOfFirst { it.type == focused.type && it.id == focused.itemId }
        .coerceAtLeast(0)

    val targetRowIndex = when {
        survivingRowIndex >= 0 && tvHomeItems(catalogs[survivingRowIndex].items).isNotEmpty() -> survivingRowIndex
        else -> catalogs.indices
            .filter { tvHomeItems(catalogs[it].items).isNotEmpty() }
            .firstOrNull { it >= oldRowIndex }
            ?: catalogs.indices.lastOrNull { tvHomeItems(catalogs[it].items).isNotEmpty() }
    }
    val targetRow = targetRowIndex?.let(catalogs::get)
        ?: return TvHomeFocusReconciliation(TvHomeFocusState(catalogs, null), recovery = null)
    val targetItems = tvHomeItems(targetRow.items)
    val targetItemIndex = oldItemIndex.coerceAtMost(targetItems.lastIndex)
    val targetItem = targetItems[targetItemIndex]
    val targetKey = TvHomeFocusKey(targetRow.id, targetItem.type, targetItem.id)
    return TvHomeFocusReconciliation(
        state = TvHomeFocusState(catalogs, targetKey),
        recovery = TvHomeFocusRecovery(targetKey, targetRowIndex, targetItemIndex),
    )
}
