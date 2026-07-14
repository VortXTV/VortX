package com.vortx.android.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
    // GROUP 3a fix (Tab S11 Ultra device round): the hero is a flat gradient placeholder with no real
    // artwork behind it (S10 brings the real rotating-featured backdrop) -- on a phone that reads as an
    // intentional cinematic panel, but stretched across a large-screen width (tablet / unfolded
    // foldable, >= the Material "expanded" width-class breakpoint) the SAME flat gradient becomes a
    // huge, mostly-empty black bar that read as a broken/blank Home (screenshot p5). The fix chosen
    // here is the smaller of the two options the plan allows: fall back to a plain rail-first layout
    // above the breakpoint instead of building S10's real rotating hero early. Phones (and the Fold's
    // narrow cover screen) are completely unaffected -- this only removes the placeholder gradient
    // block on screens wide enough that it was never going to read as intentional.
    val isLargeScreen = LocalConfiguration.current.screenWidthDp >= LARGE_SCREEN_BREAKPOINT_DP
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        if (hero != null && !isLargeScreen) {
            item { HeroHeader(hero) }
        }
        items(catalogs, key = { it.id }) { catalog ->
            // The leading Continue Watching rail carries the editorial kicker, like tvOS.
            val eyebrow = if (catalog.id == "continue") "Pick up where you left off" else null
            PosterRail(catalog = catalog, onItem = onItem, eyebrow = eyebrow)
        }
    }
}

/// Material 3's "expanded" window width-class breakpoint (large tablets / unfolded foldables), used as
/// the large-vs-phone cutoff for [HomeContent]'s hero fallback.
private const val LARGE_SCREEN_BREAKPOINT_DP = 840

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

/// The featured-hero billboard (DESIGN-SYSTEM.md §4 "Featured hero"): a full-bleed backdrop with a
/// dual scrim (here: a vertical fade to canvas, the leading-fade half is deferred to S10's real
/// artwork/rotation work — this session only re-skins the placeholder to the token set) and the
/// bottom-left content block (eyebrow kicker + serif hero title + meta line).
@Composable
private fun HeroHeader(item: MetaItem) {
    val colors = VortXTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            // Cap the hero's height BEFORE applying the aspect ratio: on a large-screen portrait
            // window (tablet / unfolded foldable, width 800-1000dp) an unclamped 16:10 of full width
            // is a 500-640dp near-black gradient block that swallows the viewport and reads as a
            // blank screen (S03 device-round finding on the Tab S11 Ultra). Phones stay under the
            // cap, so their ratio is untouched; when the cap binds, the box goes full-width at
            // 420dp tall instead (fine for a gradient; S10's real artwork brings its own sizing).
            .heightIn(max = 420.dp)
            .aspectRatio(16f / 10f)
            // GROUP 3a: a Box does not clip its children by default, so a title tall enough to exceed
            // this box's bounds (a long name at the large `type.hero` style, most likely on a wide
            // window where the box's aspect-ratio math yields a shorter box for the same font size)
            // drew past the bottom edge and, because the next LazyColumn item (the first rail) paints
            // AFTER this one, appeared to render "behind" it -- the device-round "Obsession" overlap
            // finding. Clipping plus the title's own line/overflow limit below are the two guards.
            .clipToBounds()
            .background(Brush.verticalGradient(listOf(colors.surface2, colors.canvas))),
    ) {
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
