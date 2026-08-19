package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.iptv.LiveViewModel
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.LoadingRail
import com.vortx.android.ui.components.RailHeader
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// Live TV: the engine's live-TV / channel / events catalogs rendered as rows of square CHANNEL TILES,
/// distinct from the 2:3 poster rails the rest of the app uses. The Android port of Apple's `iOSLiveView`:
/// channel art is a logo on a neutral card (not box-art), tapping a channel opens the shared
/// [DetailScreen] (whose live branch plays through the existing player), and the screen reuses the engine
/// + player wholesale -- no EPG, no M3U import. When no installed add-on exposes a live catalog the screen
/// nudges the user to the Add-ons tab rather than showing a blank surface.
@Composable
fun LiveScreen(viewModel: LiveViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    when (val s = state) {
        is UiState.Loading -> LiveLoadingColumn(modifier)
        is UiState.Error -> ErrorState(s.message, onRetry = viewModel::retry, modifier = modifier)
        is UiState.Success ->
            if (s.data.isEmpty()) {
                // Mirrors Apple `iOSLiveView.emptyState`: no CTA, just a nudge -- switching to the Add-ons
                // tab is owned by the shell, so this stays guidance rather than a button.
                EmptyState(
                    "No Live TV add-ons installed. Install an add-on that provides live TV, channels, or " +
                        "events in Settings > Add-ons and its channels will show up here.",
                    modifier,
                )
            } else {
                LiveContent(s.data, onItem, modifier)
            }
    }
}

@Composable
private fun LiveContent(rows: List<Catalog>, onItem: (MetaItem) -> Unit, modifier: Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = VortXTheme.spacing.md, bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        items(rows, key = { it.id }) { row ->
            ChannelRail(row, onItem)
        }
    }
}

/// One Live row: a titled, horizontally-scrolling band of square [ChannelTile]s. The twin of `PosterRail`
/// for live content -- same header language, but square channel tiles instead of 2:3 poster cards.
@Composable
private fun ChannelRail(catalog: Catalog, onItem: (MetaItem) -> Unit) {
    Column {
        RailHeader(title = catalog.title)
        LazyRow(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            items(catalog.items, key = { item -> "${item.type.name}|${item.id}" }) { item ->
                ChannelTile(item, onClick = { onItem(item) })
            }
        }
    }
}

/// A square (1:1) channel tile: the channel's logo (preferred) or poster, fit on a neutral surface card so
/// logos with transparency / odd aspect ratios read cleanly -- channels rarely have box-art, so a `fit` on
/// a surface beats a `fill` crop. The channel name sits below, like a poster card. Mirrors Apple's
/// `iOSLiveView.ChannelTile`.
@Composable
private fun ChannelTile(item: MetaItem, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    // Logo first (the channel mark), else poster; both are channel-identifying art.
    val artUrl = item.logo?.takeUnless { it.isBlank() } ?: item.poster?.takeUnless { it.isBlank() }
    Column(modifier = Modifier.width(CHANNEL_TILE_SIZE.dp).clickable(onClick = onClick)) {
        Box(
            modifier = Modifier
                .size(CHANNEL_TILE_SIZE.dp)
                .clip(VortXShapes.card)
                .background(colors.surface1)
                .border(0.5.dp, colors.hairline, VortXShapes.card),
            contentAlignment = Alignment.Center,
        ) {
            // The fallback broadcast glyph sits behind the art, so an art-less channel (or a logo that
            // fails to load) still reads as a channel rather than an empty card.
            Icon(
                imageVector = VortXIcons.live,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(32.dp),
            )
            if (artUrl != null) {
                AsyncImage(
                    model = artUrl,
                    contentDescription = item.name,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize().padding(VortXTheme.spacing.sm),
                )
            }
        }
        Text(
            text = item.name,
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun LiveLoadingColumn(modifier: Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = VortXTheme.spacing.xl, bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        items(List(3) { it }) { LoadingRail(title = "Loading Live TV") }
    }
}

/// Square-tile side, in dp. Roughly the phone poster width (124dp) so a Live row shares the browse rhythm.
private const val CHANNEL_TILE_SIZE = 124
