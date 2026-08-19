package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import coil3.compose.AsyncImage
import com.vortx.android.iptv.LiveViewModel
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.delay

/// The 10-foot Live TV wall: a cinematic hero band that follows the focused channel, over D-pad-focus
/// rows of square CHANNEL TILES. The Android TV port of Apple's tvOS `LiveView`: driven by the SAME engine
/// board (via [LiveViewModel], which keeps only the live-TV / channel / events catalogs), channel art is a
/// logo on a neutral surface card, and selecting a channel opens the shared [TvDetailScreen] whose live
/// branch plays through the existing player -- no EPG, no M3U import. Empty state nudges to the Add-ons
/// screen rather than a blank surface.
@Composable
fun TvLiveScreen(viewModel: LiveViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    when (val s = state) {
        is UiState.Loading -> TvLoading(modifier)
        is UiState.Error -> TvError(s.message, onRetry = viewModel::retry, modifier = modifier)
        is UiState.Success ->
            if (s.data.isEmpty()) {
                TvEmpty(
                    "No Live TV add-ons installed. Install an add-on that provides live TV, channels, or " +
                        "events in Settings > Add-ons and its channels will show up here.",
                    modifier,
                )
            } else {
                TvLiveContent(s.data, onItem, modifier)
            }
    }
}

@Composable
private fun TvLiveContent(rows: List<Catalog>, onItem: (MetaItem) -> Unit, modifier: Modifier) {
    val colors = VortXTheme.colors
    var heroItem by remember(rows.firstOrNull()?.id) {
        mutableStateOf(rows.firstOrNull()?.items?.firstOrNull())
    }
    val firstCardFocus = remember { FocusRequester() }
    var hasReceivedFocus by remember { mutableStateOf(false) }
    val heroHeight = (LocalConfiguration.current.screenHeightDp * 0.5f).dp.coerceIn(280.dp, 460.dp)

    Column(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        TvLiveHero(heroItem, modifier = Modifier.fillMaxWidth().height(heroHeight))
        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentPadding = PaddingValues(top = TvDimens.rowGap, bottom = TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            itemsIndexed(rows, key = { _, c -> c.id }) { index, catalog ->
                TvChannelRow(
                    catalog = catalog,
                    onItem = onItem,
                    onFocused = { item ->
                        hasReceivedFocus = true
                        heroItem = item
                    },
                    firstCardFocus = if (index == 0) firstCardFocus else null,
                )
            }
        }
    }

    // Seed D-pad focus on the first channel so a fresh entry lands somewhere actionable (a TV has no touch
    // to bootstrap focus). The delay lets the LazyColumn/LazyRow lay out and attach the first card's node
    // before requestFocus -- without it requestFocus throws (swallowed) and the wall lands with no focus,
    // unusable by remote. Matches TvHomeScreen's seed pattern.
    LaunchedEffect(rows.firstOrNull()?.id) {
        delay(120)
        if (!hasReceivedFocus) runCatching { firstCardFocus.requestFocus() }
    }
}

/// The featured hero band: the focused channel's art under a dual scrim (left fade for legibility, bottom
/// fade to canvas), with the bottom-left name block. The 10-foot analogue of the phone tile's quieter
/// presentation, and the Live twin of the Home `TvHero`.
@Composable
private fun TvLiveHero(item: MetaItem?, modifier: Modifier) {
    val colors = VortXTheme.colors
    Box(modifier = modifier) {
        TvBackdrop(
            url = item?.background ?: item?.logo ?: item?.poster,
            seed = item?.id ?: "vortx-live",
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
                Text(text = "LIVE TV", style = VortXTheme.type.eyebrow)
                Text(
                    text = item.name,
                    style = VortXTheme.type.hero,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.xs),
                )
            }
        }
    }
}

/// One titled focus row of square [TvChannelCard]s: the D-pad moves focus left/right within the row and
/// up/down between rows; the focused channel drives the hero via [onFocused].
@Composable
private fun TvChannelRow(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    onFocused: (MetaItem) -> Unit,
    firstCardFocus: FocusRequester?,
) {
    Column(modifier = Modifier.focusGroup()) {
        Text(
            text = catalog.title,
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(start = TvDimens.edge, bottom = VortXTheme.spacing.sm),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            itemsIndexed(catalog.items, key = { _, it -> "${it.type.name}|${it.id}" }) { i, item ->
                TvChannelCard(
                    item = item,
                    onClick = { onItem(item) },
                    onFocused = { onFocused(item) },
                    focusRequester = if (i == 0) firstCardFocus else null,
                )
            }
        }
    }
}

/// A D-pad-focusable square (1:1) channel tile: the channel's logo (preferred) or poster, fit on a neutral
/// surface card. Built on androidx.tv's `Surface` so focus scales it up, lights the accent-bright ring, and
/// fires [onClick] on the D-pad center key. Mirrors Apple tvOS `LiveView.ChannelTile`.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvChannelCard(
    item: MetaItem,
    onClick: () -> Unit,
    onFocused: () -> Unit,
    focusRequester: FocusRequester?,
) {
    val colors = VortXTheme.colors
    val artUrl = item.logo?.takeUnless { it.isBlank() } ?: item.poster?.takeUnless { it.isBlank() }
    var focused by remember { mutableStateOf(false) }
    Column(modifier = Modifier.width(TvDimens.posterWidth)) {
        Surface(
            onClick = onClick,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .onFocusChanged {
                    focused = it.isFocused
                    if (it.isFocused) onFocused()
                }
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = colors.surface1,
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface1,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = TvDimens.focusScale),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                    shape = VortXShapes.card,
                ),
            ),
        ) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = VortXIcons.live,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(44.dp),
                )
                if (artUrl != null) {
                    AsyncImage(
                        model = artUrl,
                        contentDescription = item.name,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize().padding(VortXTheme.spacing.md),
                    )
                }
            }
        }
        Text(
            text = item.name,
            style = VortXTheme.type.cardTitle.copy(
                color = if (focused) colors.textPrimary else colors.textPrimary.copy(alpha = 0.85f),
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}
