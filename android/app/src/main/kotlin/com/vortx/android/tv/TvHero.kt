package com.vortx.android.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXTheme

/// The living backdrop: whichever card is focused fills the screen with its artwork.
///
/// This is the port of tvOS `BrowseHeroBackdrop` (app/SourcesTV/SharedUI.swift) and it is the single
/// thing that makes Home read as VortX rather than a rail list on a black screen. It is PURE
/// PRESENTATION and never focusable, which is load-bearing for D-pad conduct: pressing up from the top
/// rail must land on the tab row, and it can only do that if nothing in the hero can take focus. There
/// is no `clickable`/`focusable` anywhere in this file, by design.
///
/// Not ported this round: the focus-settled ambient hero trailer (tvOS gates a muted libmpv clip in
/// behind the details after a ~3s focus debounce). It is a cut, not an oversight -- see the round's
/// report. The z-order that made it work (clip OVER the still art, UNDER the details) is preserved
/// here as the scrim ordering, so the trailer layer has a seam to land in.
@Composable
fun TvHeroBackdrop(item: MetaItem?, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    val reduced = VortXTheme.reducedMotion
    // Crossfade wants a FiniteAnimationSpec<Float>, which VortXMotion's generic AnimationSpec helpers
    // do not satisfy, so the same two tokens (HERO_MS + easing, or an instant snap under reduced
    // motion) are spelled out here rather than re-deriving a different duration.
    val spec: FiniteAnimationSpec<Float> =
        if (reduced) snap() else tween(durationMillis = VortXMotion.HERO_MS, easing = VortXMotion.easing)

    Box(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        // Keyed on the whole item so moving focus between two titles that happen to share a backdrop
        // URL still cross-fades, and so a null (nothing focused yet) fades to bare canvas.
        Crossfade(targetState = item, animationSpec = spec, label = "tvHeroArt") { hero ->
            // `background` is the engine's landscape backdrop; poster is the fallback so a catalog whose
            // items carry no backdrop still gets a living hero rather than a flat void.
            val art = hero?.background ?: hero?.poster
            if (art != null) {
                AsyncImage(
                    model = art,
                    // Decorative: the title is rendered as real text/logo in TvHeroDetails, so announcing
                    // the artwork too would just make a screen reader say the name twice.
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        // Legibility scrims, in tvOS's order. Horizontal first: the details block sits on the left, so
        // the left third goes to near-canvas while the right stays open artwork.
        Box(
            modifier = Modifier.fillMaxSize().background(
                Brush.horizontalGradient(
                    0.0f to colors.canvas.copy(alpha = 0.92f),
                    0.45f to colors.canvas.copy(alpha = 0.55f),
                    1.0f to Color.Transparent,
                ),
            ),
        )
        // Vertical: the rail strip sits on the bottom, so the art dissolves into the canvas the rails
        // ride on -- this is what stops the strip reading as a panel bolted over a photo. The small top
        // stop does the same for the tab row.
        Box(
            modifier = Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.0f to colors.canvas.copy(alpha = 0.65f),
                    0.25f to Color.Transparent,
                    0.60f to colors.canvas.copy(alpha = 0.70f),
                    1.0f to colors.canvas,
                ),
            ),
        )
    }
}

/// The hero's detail block: clearlogo (or the title in the brand serif), meta line, genre line, synopsis.
///
/// Editorial rhythm is copied from the tvOS original deliberately: a TIGHT title-to-meta pairing, then
/// air before the synopsis, so the block reads as one composed unit instead of four evenly-stacked lines
/// (DESIGN-SYSTEM §2's rhythm rule: never one spacing value everywhere).
@Composable
fun TvHeroDetails(item: MetaItem, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    val type = VortXTheme.type
    // Text sits directly on artwork, whose brightness is unknowable, so every line carries the same soft
    // drop shadow the tvOS hero uses. Without it a white title on a snowy backdrop disappears.
    val shadow = Shadow(color = Color.Black.copy(alpha = 0.55f), offset = Offset(0f, 4f), blurRadius = 14f)

    Column(modifier = modifier) {
        val logo = item.logo
        if (logo != null) {
            // The clearlogo IS the title in image form: expose the NAME to accessibility, not the art.
            AsyncImage(
                model = logo,
                contentDescription = item.name,
                contentScale = ContentScale.Fit,
                modifier = Modifier.heightIn(max = 92.dp).widthIn(max = 420.dp),
            )
        } else {
            Text(
                text = item.name,
                style = type.screenTitle.copy(shadow = shadow),
                // One line: the strip's vertical budget (TvMetrics.RAIL_STRIP_FRACTION) is solved against
                // a single-line hero title. Two lines of 40sp serif would push the synopsis into the rails.
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        val meta = heroMetaLine(item)
        if (meta != null) {
            Text(
                text = meta,
                style = type.label.copy(color = colors.textSecondary, shadow = shadow),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 14.dp),
            )
        }
        val overview = item.description
        if (!overview.isNullOrBlank()) {
            Text(
                text = overview,
                style = type.body.copy(color = colors.textSecondary, shadow = shadow),
                // tvOS shows 3; 2 here, for the vertical budget documented on RAIL_STRIP_FRACTION. This
                // is the honest place the Android hero is tighter than the Apple TV one.
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 18.dp).widthIn(max = 620.dp),
            )
        }
    }
}

/// "2019 · Movie · ★ 8.4 · Action, Sci-Fi · Resume 1:03" -- the hero's one-line identity for the focused
/// card, carrying exactly the metadata the TV poster card drops (see [TvPosterCard]'s note). Null when
/// the engine gave us none of it.
///
/// tvOS gives genres their OWN line under the meta line (`hero.genreLine` in BrowseHeroBackdrop). They
/// are folded in here instead because the Android hero has ~213dp to work in against tvOS's ~610pt (see
/// TvMetrics.RAIL_STRIP_FRACTION for the budget): a separate genre row costs 27dp the synopsis needs
/// more. Capped at two genres so the line cannot push the year and type off the end on a title the
/// engine tagged with six.
private fun heroMetaLine(item: MetaItem): String? {
    val parts = listOfNotNull(
        item.year,
        item.type.label,
        item.imdbRating?.takeIf { it.isNotBlank() }?.let { "★ $it" },
        item.genres.take(MAX_HERO_GENRES).takeIf { it.isNotEmpty() }?.joinToString(", "),
        item.resumeLabel?.let { "Resume $it" },
    )
    return parts.takeIf { it.isNotEmpty() }?.joinToString("  ·  ")
}

private const val MAX_HERO_GENRES = 2
