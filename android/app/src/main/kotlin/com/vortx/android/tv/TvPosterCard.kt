package com.vortx.android.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// A poster card for a 10-foot rail: the phone [com.vortx.android.ui.components.PosterCard]'s composition
/// (2:3 art, progress track, watched dim + check, title below) re-cut for the focus engine.
///
/// It is a separate composable rather than a flag on the phone card because the two differ in kind, not
/// degree: the phone card's active state is `collectIsPressedAsState` (a finger is on it), the TV card's
/// is FOCUS (the D-pad is on it, no touch involved), and focus additionally has to be reported OUTWARD --
/// [onFocused] is what drives the living hero behind the rails. Sharing one composable would mean a
/// touch card carrying TV focus plumbing and vice versa. The expensive part -- the Coil image path -- IS
/// shared, via [PosterArt], so there is exactly one place poster images are loaded in this app.
///
/// Note what is deliberately absent: the phone card's `subtitle` (year / type). On TV that metadata is
/// not dropped, it MOVES -- the living hero renders year, type, rating and genres for whichever card is
/// focused, at a size readable from a sofa. Repeating it under a 112dp card would be unreadable noise.
@Composable
fun TvPosterCard(
    item: MetaItem,
    onClick: () -> Unit,
    onFocused: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    var focused by remember { mutableStateOf(false) }
    // `indication = null`: the focus treatment IS the indication (TvFocus), so the stock M3 ripple would
    // only add a grey wash on top of the ember glow.
    val interactionSource = remember { MutableInteractionSource() }

    Column(
        modifier = modifier
            .width(TvMetrics.posterWidth)
            .tvFocusScale(focused)
            // MUST sit above `clickable` in the chain: onFocusChanged observes focus state of the
            // modifiers AFTER it, and `clickable` is what makes this card a focus target at all.
            .onFocusChanged { state ->
                focused = state.isFocused
                if (state.isFocused) onFocused()
            }
            // `clickable` is the whole D-pad contract in one modifier: it makes the card focusable, it
            // scrolls itself into view inside the LazyRow when focus lands on it, and it fires onClick on
            // DPAD_CENTER / ENTER. There is no TV-specific key handling to write here.
            .clickable(interactionSource = interactionSource, indication = null, onClick = onClick),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .tvFocusArt(focused)
                .clip(VortXShapes.card),
        ) {
            PosterArt(item.poster, item.name)
            // One read, so the "finished" dim and the progress track can never disagree about it.
            val progress = item.progress
            if (progress != null && progress >= WATCHED_FRACTION) {
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                Icon(
                    imageVector = VortXIcons.checkmarkCircle,
                    contentDescription = "Watched",
                    tint = colors.accentBright,
                    modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).size(22.dp),
                )
            }
            if (progress != null && progress in 0f..1f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(4.dp)
                        .background(colors.surface3.copy(alpha = 0.6f)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(progress.coerceIn(0f, 1f))
                            .fillMaxSize()
                            .background(colors.accent),
                    )
                }
            }
        }
        // One line, always: the rail strip's height budget (TvMetrics.RAIL_STRIP_FRACTION) is solved
        // against a fixed card height, so a two-line title would push the first rail out of the strip.
        // The focused title's FULL name is never truncated to the user -- it is the hero's headline.
        Text(
            text = item.name,
            style = VortXTheme.type.cardTitle.copy(
                color = if (focused) colors.textPrimary else colors.textSecondary,
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/// At/over this watched fraction a Continue Watching card is treated as finished (dim + check) rather
/// than resumable. Mirrors the phone card's `watched` flag, which the engine sets on the same threshold.
private const val WATCHED_FRACTION = 0.95f
