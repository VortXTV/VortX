package com.vortx.android.ui.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.home.TOP_PICKS_CATALOG_ID
import com.vortx.android.home.SIMKL_WATCHLIST_CATALOG_ID
import com.vortx.android.home.TRAKT_WATCHLIST_CATALOG_ID
import com.vortx.android.home.UPCOMING_EPISODES_CATALOG_ID
import com.vortx.android.home.UPCOMING_MOVIES_CATALOG_ID
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel
import kotlinx.coroutines.delay

/// The TV Home browse wall: a cinematic hero band that follows the focused tile, over D-pad-focus poster
/// rows. Driven by the SAME [HomeViewModel] the phone Home uses (it collects the engine's continuous
/// `homeUpdates` stream), so Continue Watching + every add-on catalog rail arrive from one data path -- this
/// screen only changes the presentation to a 10-foot, focus-first layout. Loading/error are first-class
/// states, never a bare black screen.
@Composable
fun TvHomeScreen(viewModel: HomeViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val contentOwnerGeneration by viewModel.contentOwnerGeneration.collectAsStateWithLifecycle()
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
                TvHomeContent(s.data, contentOwnerGeneration, onItem, modifier)
            }
    }
}

@Composable
private fun TvHomeContent(
    catalogs: List<Catalog>,
    contentOwnerGeneration: Long,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier,
) {
    val colors = VortXTheme.colors
    val visibleCatalogs = remember(catalogs) { tvHomeCatalogs(catalogs) }
    // Keep the focused identity across incremental updates only while that exact type/id is still visible.
    // A profile/account catalog replacement falls back in this composition, then commits the fallback key
    // so a removed identity cannot return later and resurrect the previous owner's hero.
    var heroState by remember { mutableStateOf(TvHomeHeroState(contentOwnerGeneration, null)) }
    val heroSelection = tvHomeHeroSelection(heroState, contentOwnerGeneration, visibleCatalogs)
    SideEffect {
        if (heroState != heroSelection.state) heroState = heroSelection.state
    }

    // Seed D-pad focus on the first tile of the first row so a fresh TV entry lands somewhere actionable
    // instead of nowhere (a TV has no touch to bootstrap focus). Guarded: requestFocus throws if the node
    // is not attached yet, so it runs after a frame and swallows the race.
    val firstCardFocus = remember { FocusRequester() }

    val heroHeight = (LocalConfiguration.current.screenHeightDp * 0.5f).dp.coerceIn(280.dp, 460.dp)

    Column(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        TvHero(heroSelection.item, modifier = Modifier.fillMaxWidth().height(heroHeight))
        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentPadding = PaddingValues(top = TvDimens.rowGap, bottom = TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            itemsIndexed(visibleCatalogs, key = { _, c -> c.id }) { index, catalog ->
                TvCatalogRow(
                    catalog = catalog,
                    onItem = onItem,
                    onFocused = {
                        heroState = TvHomeHeroState(contentOwnerGeneration, tvHomeItemKey(it))
                    },
                    firstCardFocus = if (index == 0) firstCardFocus else null,
                )
            }
        }
    }

    LaunchedEffect(Unit) {
        delay(120)
        runCatching { firstCardFocus.requestFocus() }
    }
}

/// The featured hero band: the focused title's backdrop under a dual scrim (left fade for text legibility,
/// bottom fade to canvas so the rows sit on solid), with the bottom-left title/meta block. The 10-foot
/// analogue of the phone [com.vortx.android.ui.screens.HomeScreen]'s `HeroHeader`, but art-backed and
/// focus-reactive rather than a flat placeholder.
@Composable
private fun TvHero(item: MetaItem?, modifier: Modifier) {
    val colors = VortXTheme.colors
    Box(modifier = modifier) {
        TvBackdrop(
            url = item?.background ?: item?.poster,
            seed = item?.id ?: "vortx",
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.horizontalGradient(0f to colors.canvas, 0.6f to Color.Transparent)),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(0.35f to Color.Transparent, 1f to colors.canvas)),
        )
        if (item != null) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth(0.6f)
                    .padding(start = TvDimens.edge, end = TvDimens.edge, bottom = TvDimens.edge),
            ) {
                Text(text = item.type.label.uppercase(), style = VortXTheme.type.eyebrow)
                Text(
                    text = item.name,
                    style = VortXTheme.type.hero,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.xs),
                )
                val meta = listOfNotNull(
                    item.caption ?: item.year,
                    item.imdbRating?.let { "★ $it" },
                    item.genres.firstOrNull(),
                ).joinToString("   ·   ")
                if (meta.isNotBlank()) {
                    Text(
                        text = meta,
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                    )
                }
                item.description?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        text = it,
                        style = VortXTheme.type.body.copy(color = colors.textSecondary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                    )
                }
            }
        }
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
    firstCardFocus: FocusRequester?,
) {
    val visibleItems = remember(catalog.items) { tvHomeItems(catalog.items) }
    Column {
        val eyebrow = when (catalog.id) {
            "continue" -> "Pick up where you left off"
            TOP_PICKS_CATALOG_ID -> "Based on what you watch"
            UPCOMING_EPISODES_CATALOG_ID, UPCOMING_MOVIES_CATALOG_ID -> "Coming soon"
            TRAKT_WATCHLIST_CATALOG_ID -> "From Trakt"
            SIMKL_WATCHLIST_CATALOG_ID -> "From SIMKL"
            else -> null
        }
        Column(modifier = Modifier.padding(start = TvDimens.edge, bottom = VortXTheme.spacing.sm)) {
            if (eyebrow != null) {
                Text(text = eyebrow.uppercase(), style = VortXTheme.type.eyebrow)
            }
            Text(text = catalog.title, style = VortXTheme.type.sectionTitle)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            itemsIndexed(visibleItems, key = { _, it -> tvHomeItemKey(it) }) { i, item ->
                TvPosterCard(
                    item = item,
                    onClick = { onItem(item) },
                    onFocused = { onFocused(item) },
                    focusRequester = if (firstCardFocus != null && i == 0) firstCardFocus else null,
                )
            }
        }
    }
}

/**
 * A [Catalog.id] is the engine's stable add-on-qualified row identity (`base|type|catalog`), so two
 * rows with the same id are the same logical rail. Keep the first engine-ranked occurrence and retain
 * rows from different add-ons even when their bare manifest catalog names match.
 */
internal fun tvHomeCatalogs(catalogs: List<Catalog>): List<Catalog> =
    catalogs.distinctBy { it.id }

/**
 * A content identity is type plus id: a movie and series may legitimately share an external id, while
 * two entries with the same type/id in one rail are the same title repeated by an add-on or page edge.
 */
internal fun tvHomeItems(items: List<MetaItem>): List<MetaItem> =
    items.distinctBy(::tvHomeItemKey)

internal fun tvHomeItemKey(item: MetaItem): String = "${item.type.name}|${item.id}"

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
        state = TvHomeHeroState(contentOwnerGeneration, selected?.let(::tvHomeItemKey)),
        item = selected,
    )
}
