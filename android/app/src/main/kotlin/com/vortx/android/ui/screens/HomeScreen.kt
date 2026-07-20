package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.LoadingRail
import com.vortx.android.ui.components.PosterRail
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel

/// Home: a featured hero (the first Continue Watching / Popular item) over the add-on catalog rails,
/// the same composition the iOS and Apple TV apps lead with (DESIGN-SYSTEM.md §4 "Home"). Driven by
/// [HomeViewModel] so loading and error are first-class states, not an empty screen.
@Composable
fun HomeScreen(viewModel: HomeViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    when (val s = state) {
        is UiState.Loading -> LoadingColumn(modifier)
        is UiState.Error -> ErrorState(s.message, onRetry = viewModel::load, modifier = modifier)
        is UiState.Success ->
            // Belt-and-braces: the ViewModel never publishes an empty Success today, but if that
            // contract ever regresses, render the composed empty state -- a bare black Home screen
            // (the S03 device-round symptom) must be unrepresentable here.
            if (s.data.isEmpty()) {
                EmptyState(
                    "No catalogs yet. Check your connection, or sign in from Settings.",
                    modifier,
                    actionLabel = "Retry",
                    onAction = viewModel::load,
                )
            } else {
                HomeContent(s.data, onItem, modifier)
            }
    }
}

@Composable
private fun HomeContent(catalogs: List<Catalog>, onItem: (MetaItem) -> Unit, modifier: Modifier) {
    val hero = catalogs.firstOrNull()?.items?.firstOrNull()
    // The featured hero is the first item of the first rail (Continue Watching, else the leading add-on
    // catalog) -- the SAME data the rails below already render. It now loads that title's real
    // backdrop/poster art (see [HeroHeader]), so the earlier large-screen gate (which hid the hero on
    // tablets/foldables precisely BECAUSE it was an artwork-less flat gradient that stretched into a
    // "huge, mostly-empty black bar", the Tab S11 Ultra GROUP 3a finding) no longer applies: with real
    // art plus the height cap in [HeroHeader], the panel reads as intentional at any width. The blank
    // hero the device round hit was this billboard never binding any image at all.
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        if (hero != null) {
            item { HeroHeader(hero, onItem) }
        }
        items(catalogs, key = { it.id }) { catalog ->
            // The leading Continue Watching rail carries the editorial kicker, like tvOS.
            val eyebrow = if (catalog.id == "continue") "Pick up where you left off" else null
            PosterRail(catalog = catalog, onItem = onItem, eyebrow = eyebrow)
        }
    }
}

@Composable
private fun LoadingColumn(modifier: Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = VortXTheme.spacing.xl, bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        items(List(3) { it }) { LoadingRail() }
    }
}

/// The featured-hero billboard (DESIGN-SYSTEM.md §4 "Featured hero"): the featured title's full-bleed
/// backdrop (falling back to its poster, then to a plain gradient when neither has loaded) under a
/// bottom scrim that fades to canvas, with the bottom-left content block (eyebrow kicker + serif hero
/// title + meta line). Tapping it opens the title. The S10 rotation/leading-fade work is still to come.
@Composable
private fun HeroHeader(item: MetaItem, onItem: (MetaItem) -> Unit) {
    val colors = VortXTheme.colors
    // The featured title's real artwork, drawn from the SAME catalog data the rails use: prefer the
    // wide featured backdrop ([MetaItem.background], what browse pages lead with and what the engine's
    // `parseMetaPreview` fills for add-on catalog items), fall back to the poster (Continue Watching
    // items carry only that). Both go through the one app-wide Coil loader, exactly like [PosterArt].
    // Null/blank on both (the offline preview, or a still-hydrating first item) keeps the plain
    // gradient so the panel stays intentional rather than empty -- the sensible fallback.
    val backdropUrl = item.background?.takeUnless { it.isBlank() } ?: item.poster?.takeUnless { it.isBlank() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            // Cap the hero's height BEFORE applying the aspect ratio: on a large-screen portrait
            // window (tablet / unfolded foldable, width 800-1000dp) an unclamped 16:10 of full width
            // is a 500-640dp block that swallows the viewport (S03 device-round finding on the Tab S11
            // Ultra). Phones stay under the cap, so their ratio is untouched; when the cap binds, the
            // box goes full-width at 420dp tall instead.
            .heightIn(max = 420.dp)
            .aspectRatio(16f / 10f)
            // GROUP 3a: a Box does not clip its children by default, so a title tall enough to exceed
            // this box's bounds (a long name at the large `type.hero` style, most likely on a wide
            // window where the box's aspect-ratio math yields a shorter box for the same font size)
            // drew past the bottom edge and, because the next LazyColumn item (the first rail) paints
            // AFTER this one, appeared to render "behind" it -- the device-round "Obsession" overlap
            // finding. Clipping plus the title's own line/overflow limit below are the two guards.
            .clipToBounds()
            // Tap the billboard to open the featured title, the same action a poster tap performs.
            .clickable { onItem(item) }
            // Placeholder fill for when there is no artwork yet; hidden behind the image when there is.
            .background(Brush.verticalGradient(listOf(colors.surface2, colors.canvas))),
    ) {
        if (backdropUrl != null) {
            AsyncImage(
                model = backdropUrl,
                contentDescription = item.name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            // Bottom-anchored scrim so the eyebrow/title/meta stay legible over any artwork: the
            // DESIGN-SYSTEM hero's fade to canvas, without dimming the top of the image.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0.35f to Color.Transparent,
                            1f to colors.canvas,
                        ),
                    ),
            )
        }
        Column(modifier = Modifier.align(Alignment.BottomStart).padding(VortXTheme.spacing.edge)) {
            Text(text = item.type.label.uppercase(), style = VortXTheme.type.eyebrow)
            Text(
                text = item.name,
                style = VortXTheme.type.hero,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = VortXTheme.spacing.xs),
            )
            item.year?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}
