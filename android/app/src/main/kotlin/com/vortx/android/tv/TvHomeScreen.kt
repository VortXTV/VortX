package com.vortx.android.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel

/// VortX Home on a television: a living hero backdrop with the catalog rails caged in a bottom strip.
///
/// Modelled on tvOS `HomeView` (app/SourcesTV/HomeView.swift), and driven by the SAME [HomeViewModel]
/// the phone Home uses -- not a copy of it. That reuse is the whole reason a TV port fits in this
/// window: the ViewModel already collects the engine's continuous `homeUpdates` stream (rails settle in
/// add-on by add-on, a sign-in swaps the rail set live) and already models Loading / Error / Success as
/// first-class states with a 15s watchdog against a silent black screen. None of that is re-derived
/// here; only the presentation is 10-foot.
///
/// The two structural ideas ported from tvOS:
///  1. The hero is driven by FOCUS, not by a timer or a "featured" flag. Whatever card the D-pad is on
///     is what fills the screen. That is what makes browsing feel alive.
///  2. The rails live in a bottom STRIP. The focus engine scrolls focused rows within that strip's
///     viewport, so a row is geometrically incapable of riding up over the hero (the tvOS
///     `heroBottomStrip` comment makes exactly this argument).
/// [autoFocusFirstCard] asks this screen to pull focus onto its first poster once it has laid out. It is
/// a PARAMETER, owned by the shell, rather than something this screen decides for itself, and that is
/// load-bearing: the tab row selects on focus, so returning to the Home tab re-enters this composable
/// while the user's focus is still up in the tab row. A self-driven `LaunchedEffect(Unit)` here would
/// then yank focus down into the rails the instant they land on Home, making it impossible to travel
/// along the tab row past it. The shell hands `true` exactly once, at launch (see [VortXTvApp]), and
/// this screen reports back through [onAutoFocusConsumed].
@Composable
fun TvHomeScreen(
    viewModel: HomeViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    autoFocusFirstCard: Boolean = false,
    onAutoFocusConsumed: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    when (val s = state) {
        is UiState.Loading -> TvCenteredMessage("Loading your catalogs", modifier)
        is UiState.Error -> Box(modifier.fillMaxSize().tvSafeContentPadding(), Alignment.Center) {
            // The phone's composed error card, with a focusable Retry -- reused rather than reskinned,
            // so a TV error is never a dead end the D-pad cannot act on.
            ErrorState(s.message, onRetry = viewModel::load)
        }
        is UiState.Success ->
            if (s.data.isEmpty()) {
                Box(modifier.fillMaxSize().tvSafeContentPadding(), Alignment.Center) {
                    EmptyState(
                        "No catalogs yet. Check your connection, or sign in from Settings.",
                        actionLabel = "Retry",
                        onAction = viewModel::load,
                    )
                }
            } else {
                TvHomeContent(s.data, onItem, modifier, autoFocusFirstCard, onAutoFocusConsumed)
            }
    }
}

@Composable
private fun TvHomeContent(
    catalogs: List<Catalog>,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier,
    autoFocusFirstCard: Boolean,
    onAutoFocusConsumed: () -> Unit,
) {
    // The focused title drives the hero. Seeded with the first card so the hero is composed on arrival
    // rather than snapping in after the user's first D-pad press.
    val firstItem = catalogs.firstOrNull()?.items?.firstOrNull()
    var focusedItem by remember(firstItem?.id) { mutableStateOf(firstItem) }

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        // The strip is a fraction of the ACTUAL viewport, not of an assumed 1080p panel: Android TV ships
        // 720p sticks and 4K boxes at several densities. See TvMetrics.RAIL_STRIP_FRACTION.
        val stripHeight = maxHeight * TvMetrics.RAIL_STRIP_FRACTION

        // Layer 1: the hero, full-bleed BEHIND everything including under the overscan inset. Artwork is
        // allowed to lose its edge to overscan (TV-TR wants an opaque full-screen background); content is
        // not, which is what tvSafeContentPadding below is for.
        TvHeroBackdrop(item = focusedItem)

        // Layer 2: content, inside the overscan-safe box.
        Column(modifier = Modifier.fillMaxSize()) {
            // The hero's detail block takes whatever the strip leaves, and is bottom-aligned within it so
            // the synopsis always sits a fixed gap above the first rail header -- the same trick as tvOS's
            // `detailsBottom`, which pins the block to the strip's edge rather than to the top of the
            // screen, so the two can never collide as chrome above shifts.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .clipToBounds()
                    .padding(
                        start = TvMetrics.overscanHorizontal,
                        end = TvMetrics.overscanHorizontal,
                        top = TvMetrics.overscanVertical,
                        bottom = HERO_TO_STRIP_GAP,
                    ),
                contentAlignment = Alignment.BottomStart,
            ) {
                focusedItem?.let { TvHeroDetails(it) }
            }

            TvRailStrip(
                catalogs = catalogs,
                onItem = onItem,
                onFocusedItem = { focusedItem = it },
                autoFocusFirstCard = autoFocusFirstCard,
                onAutoFocusConsumed = onAutoFocusConsumed,
                modifier = Modifier.fillMaxWidth().height(stripHeight),
            )
        }
    }
}

/// The caged rail strip: a vertically scrolling list of rails, masked so rows dissolve at its top edge.
@Composable
private fun TvRailStrip(
    catalogs: List<Catalog>,
    onItem: (MetaItem) -> Unit,
    onFocusedItem: (MetaItem) -> Unit,
    autoFocusFirstCard: Boolean,
    onAutoFocusConsumed: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val fadePx = with(LocalDensity.current) { TvMetrics.railStripFade.toPx() }
    // Focus at app launch lands on the first card of the first rail (see TvHomeScreen's kdoc for why the
    // shell, not this screen, decides when). Without it nothing on screen is focused at launch and the
    // user's first D-pad press is spent merely getting focus into the UI.
    val firstCard = remember { FocusRequester() }

    LazyColumn(
        modifier = modifier
            // Offscreen compositing is required for the DstIn mask below to have anything to erase:
            // without it the gradient blends against the window instead of this layer's own pixels.
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                // Port of tvOS `heroBottomStrip`'s mask: clear -> black over the first 50pt, black below.
                // A row scrolling up out of the strip fades into the hero rather than clipping against a
                // hard line. DstIn keeps this layer's pixels only where the gradient is opaque.
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(Color.Transparent, Color.Black),
                        startY = 0f,
                        endY = fadePx,
                    ),
                    blendMode = BlendMode.DstIn,
                )
            },
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        contentPadding = PaddingValues(bottom = TvMetrics.overscanVertical),
    ) {
        itemsIndexed(catalogs, key = { _, catalog -> catalog.id }) { index, catalog ->
            TvPosterRail(
                catalog = catalog,
                onItem = onItem,
                onFocusedItem = onFocusedItem,
                // Continue Watching carries the editorial kicker and is pinned first by the engine's own
                // board order, matching the phone Home and tvOS.
                eyebrow = if (catalog.id == CONTINUE_WATCHING_ID) "Pick up where you left off" else null,
                firstCardFocusRequester = if (index == 0) firstCard else null,
            )
        }
    }

    if (autoFocusFirstCard) {
        LaunchedEffect(Unit) {
            // A LazyColumn composes its children during LAYOUT, not during the composition this effect is
            // launched from, so the first card's FocusRequester is not attached yet at this point. Waiting
            // one frame lets the strip lay out its first row before we ask for focus.
            withFrameNanos { }
            // Even then, requestFocus THROWS (rather than returning false) if nothing is attached -- an
            // empty first rail, or a recomposition race. Focus-on-launch is a nicety; failing to get it
            // must never take the app down. Worst case the user's first D-pad press lands focus instead.
            runCatching { firstCard.requestFocus() }
            // Consumed either way: a retry loop here would fight the user for focus on every recomposition,
            // which is the exact failure this flag exists to prevent.
            onAutoFocusConsumed()
        }
    }
}

/// One rail: the shared editorial header, then a focus-navigable row of TV poster cards.
@Composable
private fun TvPosterRail(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    onFocusedItem: (MetaItem) -> Unit,
    eyebrow: String?,
    firstCardFocusRequester: FocusRequester?,
) {
    Column {
        // The two-line editorial header (eyebrow kicker + section title), same roles as the phone
        // RailHeader; re-laid out here only because it needs the TV overscan inset as its start padding.
        Column(modifier = Modifier.padding(start = TvMetrics.overscanHorizontal, bottom = VortXTheme.spacing.xs)) {
            if (eyebrow != null) {
                Text(text = eyebrow.uppercase(), style = VortXTheme.type.eyebrow)
            }
            Text(text = catalog.title, style = VortXTheme.type.sectionTitle)
        }
        LazyRow(
            // Overscan on both ends, so the first card is not jammed against a cropped screen edge and
            // the last one can still scroll clear of it.
            contentPadding = PaddingValues(horizontal = TvMetrics.overscanHorizontal),
            horizontalArrangement = Arrangement.spacedBy(TvMetrics.railItemGap),
        ) {
            items(catalog.items, key = { it.id }) { item ->
                TvPosterCard(
                    item = item,
                    onClick = { onItem(item) },
                    onFocused = { onFocusedItem(item) },
                    modifier = if (firstCardFocusRequester != null && item.id == catalog.items.firstOrNull()?.id) {
                        Modifier.focusRequester(firstCardFocusRequester)
                    } else {
                        Modifier
                    },
                )
            }
        }
    }
}

/// A calm full-screen line of copy (the strip's loading state). Deliberately not a spinner
/// (DESIGN-SYSTEM §3 bans a bare spinner as a whole state).
@Composable
private fun TvCenteredMessage(text: String, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize().tvSafeContentPadding(), contentAlignment = Alignment.Center) {
        Text(text = text, style = VortXTheme.type.sectionTitle.copy(color = VortXTheme.colors.textSecondary))
    }
}

/// The overscan-safe inset (TV-OV) for a screen that fills the viewport with CONTENT rather than art.
fun Modifier.tvSafeContentPadding(): Modifier = this.padding(
    horizontal = TvMetrics.overscanHorizontal,
    vertical = TvMetrics.overscanVertical,
)

/// Breathing room between the hero's synopsis and the first rail header. tvOS uses the strip height plus
/// a 50pt gap (`detailsBottom: 520` over a 470 strip); this is that gap, applied as padding instead of an
/// absolute offset because the strip here is already its own laid-out sibling.
private val HERO_TO_STRIP_GAP = 24.dp

/// The engine's id for the pinned Continue Watching rail, matching the phone Home's check.
private const val CONTINUE_WATCHING_ID = "continue"
