package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.ratings.CardRatingStore
import com.vortx.android.ratings.MdbListRatings
import com.vortx.android.ratings.RatingsFormat
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass

/**
 * A small rating badge for a catalog CARD whose visible artwork does NOT already carry a baked rating, the
 * Kotlin port of Apple `CardRatingBadge` (app/SourcesShared/CardRatingBadge.swift). The portrait poster gets
 * its rating baked in server-side by poster.vortx.tv / ERDB when the ratings feature is on (default), so a
 * baked poster is never double-badged; this badge draws only when [active] is false-for-baked (the caller
 * passes `!PosterArtwork.bakesRatings(forId = id)`), i.e. when the art is clean.
 *
 * It renders the SAME cross-provider set the detail row and the baked poster do (IMDb + RT + MC + TMDB,
 * formatted once in [RatingsFormat]), capped by [maxScores]. Values are looked up by id from VortX's own
 * keyless ratings service (the SAME numbers the baker uses), async and fail-soft via the process-memoized
 * [CardRatingStore]: nothing shows until a rating resolves, a miss (non-`tt` id, offline, or no rating)
 * shows nothing, and a title carrying only IMDb shows only IMDb. Results are memoized per id so scrolling a
 * rail never refetches.
 */
@Composable
fun CardRatingBadge(
    id: String,
    type: String,
    active: Boolean = true,
    glyphSize: Int = 8,
    textSize: Int = 10,
    maxScores: Int = 2,
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
    RatingBadgePlate(tokens = tokens, glyphSize = glyphSize, textSize = textSize, modifier = modifier)
}

/**
 * The badge itself: ONE capsule of VortX glass, sized tight to its scores, floating over the artwork. The
 * IMDb value is the anchor (a third larger, its decimal set apart), a hairline divider sets it off from the
 * aggregators, and each aggregator is a tracked uppercase lettermark followed by its value. Digits are
 * monospaced so a scrolling rail never reflows. Mirrors Apple `RatingBadgePlate`.
 */
@Composable
private fun RatingBadgePlate(
    tokens: List<RatingsFormat.Token>,
    glyphSize: Int,
    textSize: Int,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    val figure = (textSize * 1.3f)
    val decimal = (figure * 0.76f)
    val valueSize = maxOf(textSize * 0.88f, 9f)
    val markSize = maxOf(textSize * 0.72f, 8f)

    Row(
        modifier = modifier
            .clip(VortXShapes.pill)
            .vortxGlass(
                shape = VortXShapes.pill,
                fillAlpha = VortXGlass.badgeFillAlpha,
                shadow = VortXGlass.Shadow.disc,
            )
            .padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        tokens.forEachIndexed { index, token ->
            if (index > 0) {
                if (tokens[index - 1].isImdb) {
                    // Hairline divider that sets the anchor apart from the aggregators (Apple `divider`).
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 5.dp)
                            .size(width = 1.dp, height = (figure * 0.72f).dp)
                            .clip(VortXShapes.pill)
                            .background(colors.textPrimary.copy(alpha = 0.22f)),
                    )
                } else {
                    Spacer(Modifier.width((textSize * 0.5f).dp))
                }
            }
            if (token.isImdb) {
                Anchor(token, colors.accent, colors.textPrimary, colors.textSecondary, figure, decimal, glyphSize)
            } else {
                Aggregator(token, colors.textTertiary, colors.textSecondary, markSize, valueSize)
            }
        }
    }
}

@Composable
private fun Anchor(
    token: RatingsFormat.Token,
    accent: Color,
    primary: Color,
    secondary: Color,
    figureSize: Float,
    decimalSize: Float,
    glyphSize: Int,
) {
    val (head, tail) = splitDecimal(token.value)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(
            imageVector = VortXIcons.starFill,
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(glyphSize.dp),
        )
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = head,
                color = primary,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = figureSize.sp,
            )
            if (tail.isNotEmpty()) {
                Text(
                    text = tail,
                    color = secondary,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = decimalSize.sp,
                )
            }
        }
    }
}

@Composable
private fun Aggregator(
    token: RatingsFormat.Token,
    labelColor: Color,
    valueColor: Color,
    markSize: Float,
    valueSize: Float,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = token.label.uppercase(),
            color = labelColor,
            fontWeight = FontWeight.SemiBold,
            fontSize = markSize.sp,
            textAlign = TextAlign.Center,
        )
        Text(
            text = token.value,
            color = valueColor,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            fontSize = valueSize.sp,
        )
    }
}

/** "8.3" -> ("8", ".3"); a percentage or a bare metascore comes back whole. Apple `splitDecimal`. */
private fun splitDecimal(v: String): Pair<String, String> {
    val dot = v.indexOf('.')
    return if (dot < 0) v to "" else v.substring(0, dot) to v.substring(dot)
}
