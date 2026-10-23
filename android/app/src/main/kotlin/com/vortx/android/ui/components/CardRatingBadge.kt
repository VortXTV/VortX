package com.vortx.android.ui.components

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.vortx.android.ratings.CardRatingStore
import com.vortx.android.ratings.MdbListRatings
import com.vortx.android.ratings.RatingsFormat
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.vortxGlass

/**
 * A small rating badge for a catalog CARD whose visible artwork does NOT already carry a baked rating, the
 * Kotlin port of Apple `CardRatingBadge` (app/SourcesShared/CardRatingBadge.swift). The portrait poster gets
 * its rating baked in server-side by poster.vortx.tv / ERDB when the ratings feature is on (default), so a
 * baked poster is never double-badged; this badge draws only when [active] is false-for-baked (the caller
 * passes `!PosterArtwork.bakesRatings(forId = id)`), i.e. when the art is clean.
 *
 * It renders the SAME cross-provider set the detail row and the baked poster do (IMDb + RT + MC + TMDB,
 * formatted once in [RatingsFormat]), as many as fit the card's width ([maxScores] caps it outright).
 * Values are looked up by id from VortX's own keyless ratings service (the SAME numbers the baker
 * uses), async and fail-soft via the process-memoized
 * [CardRatingStore]: nothing shows until a rating resolves, a miss (non-`tt` id, offline, or no rating)
 * shows nothing, and a title carrying only IMDb shows only IMDb. Results are memoized per id so scrolling a
 * rail never refetches.
 */
@Composable
fun CardRatingBadge(
    id: String,
    type: String,
    active: Boolean = true,
    textSize: Int = 10,
    maxScores: Int? = null,
    modifier: Modifier = Modifier,
) {
    var ratings by remember(id) { mutableStateOf<MdbListRatings?>(null) }

    // Key on id AND active so the lookup (re)runs when the card recycles to a new id and when `active` flips
    // true after the art resolves; skips the network entirely while inactive or for a non-`tt` id.
    LaunchedEffect(id, active) {
        ratings = if (active && id.startsWith("tt")) CardRatingStore.ratings(id, type) else null
    }

    val resolved = ratings
    if (!active || resolved == null) return
    val tokens = RatingsFormat.tokens(resolved, limit = maxScores)
    if (tokens.isEmpty()) return
    RatingBadgePlate(tokens = tokens, textSize = textSize, modifier = modifier)
}

/**
 * The plate for scores already in hand (an episode's IMDb / TMDB / Trakt), with the same fit-to-width
 * behaviour as [CardRatingBadge].
 */
@Composable
fun RatingScoresPlate(
    ratings: MdbListRatings,
    textSize: Int = 11,
    modifier: Modifier = Modifier,
) {
    val tokens = RatingsFormat.tokens(ratings)
    if (tokens.isEmpty()) return
    RatingBadgePlate(tokens = tokens, textSize = textSize, modifier = modifier)
}

/**
 * The badge itself: ONE capsule of VortX glass, sized tight to its scores, floating over the artwork. Each score
 * is its service's mark beside the value ([RatingScore]), so the plate reads at a glance with no lettermarks to
 * decode. Every score is measured at its natural size, then as many as the card's width holds are placed, in
 * priority order (headline scores first); nothing is squeezed or wrapped. Mirrors Apple `RatingBadgePlate`.
 */
@Composable
private fun RatingBadgePlate(
    tokens: List<RatingsFormat.Token>,
    textSize: Int,
    modifier: Modifier = Modifier,
) {
    val gap = (textSize * 0.75f).dp
    Layout(
        modifier = modifier
            .clip(VortXShapes.pill)
            .vortxGlass(
                shape = VortXShapes.pill,
                fillAlpha = VortXGlass.badgeFillAlpha,
                shadow = VortXGlass.Shadow.disc,
            )
            .padding(start = (textSize * 0.4f).dp, end = (textSize * 0.7f).dp, top = (textSize * 0.36f).dp,
                bottom = (textSize * 0.36f).dp)
            .semantics {
                contentDescription = "Ratings: " + tokens.joinToString(", ") { "${it.label} ${it.value}" }
            },
        content = { tokens.forEach { token -> RatingScore(token, textSize) } },
    ) { measurables, constraints ->
        val gapPx = gap.roundToPx()
        val placed = ArrayList<Placeable>(measurables.size)
        var width = 0
        var height = 0
        for (measurable in measurables) {
            val placeable = measurable.measure(Constraints())
            val next = width + (if (placed.isEmpty()) 0 else gapPx) + placeable.width
            if (placed.isNotEmpty() && next > constraints.maxWidth) break
            placed += placeable
            width = next
            height = maxOf(height, placeable.height)
        }
        layout(width, height) {
            var x = 0
            for (placeable in placed) {
                placeable.placeRelative(x, (height - placeable.height) / 2)
                x += placeable.width + gapPx
            }
        }
    }
}
