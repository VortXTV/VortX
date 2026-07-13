package com.stremiox.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.toArgb
import com.stremiox.android.ui.theme.VortXIcons
import com.stremiox.android.ui.theme.VortXMotion
import com.stremiox.android.ui.theme.VortXShapes
import com.stremiox.android.ui.theme.VortXTheme
import com.stremiox.android.ui.theme.vortxShadow

/// The canonical poster card (DESIGN-SYSTEM.md §3 "Poster card"): 2:3 art, card radius, `rest` shadow,
/// title below in label style. Press/focus: lift + scale(~1.03) + glow + title brightens to
/// textPrimary. [watched] dims the art and shows a check badge; [progress] (0f..1f, null = not in
/// progress) draws a 3px accent track under the art. [art] is a placeholder-friendly slot — until Coil
/// lands (S03), it defaults to [DefaultPosterArt]; a real image loader drops in behind the same slot
/// with no call-site changes.
@Composable
fun PosterCard(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    watched: Boolean = false,
    progress: Float? = null,
    enabled: Boolean = true,
    art: @Composable BoxScope.() -> Unit = { DefaultPosterArt(title) },
) {
    val colors = VortXTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val reduced = VortXTheme.reducedMotion
    val active = pressed && enabled
    val scale by animateFloatAsState(
        targetValue = if (active) VortXMotion.POSTER_FOCUS_SCALE else 1f,
        animationSpec = VortXMotion.heroAware(reduced),
        label = "posterScale",
    )
    val elevationSpec = if (active) VortXTheme.elevation.glow(colors.accent) else VortXTheme.elevation.rest

    Column(
        modifier = modifier
            .scale(scale)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .vortxShadow(elevationSpec, VortXShapes.card)
                .clip(VortXShapes.card),
        ) {
            art()
            if (watched) {
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                Icon(
                    imageVector = VortXIcons.checkmarkCircle,
                    contentDescription = "Watched",
                    tint = colors.accentBright,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp)
                        .size(20.dp),
                )
            }
            if (progress != null && progress in 0f..1f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(3.dp)
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
        Text(
            text = title,
            style = VortXTheme.type.cardTitle.copy(color = if (active) colors.textPrimary else colors.textPrimary.copy(alpha = 0.92f)),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
        if (subtitle != null) {
            Text(
                text = subtitle,
                style = VortXTheme.type.label.copy(color = colors.textTertiary, fontSize = 12.sp),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/// Deterministic brand-tinted gradient placeholder, seeded by [title] so a grid of unloaded posters
/// still reads as intentional/varied rather than identical gray boxes (the load-time placeholder
/// behind a real image once Coil lands, S03).
@Composable
fun DefaultPosterArt(title: String) {
    val accent = VortXTheme.colors.accent
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(posterBrush(title, accent)),
    ) {
        Text(
            text = title,
            style = VortXTheme.type.label.copy(color = Color.White.copy(alpha = 0.92f)),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomStart).padding(10.dp),
        )
    }
}

/// Deterministic two-stop gradient from a seed string, hued around the live accent so a whole grid of
/// placeholders stays in the current theme's family while every card still differs.
private fun posterBrush(seed: String, accent: Color): Brush {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(accent.toArgb(), hsv)
    val h = seed.hashCode()
    val hueShift = ((h ushr 8) % 60) - 30
    val hue = ((hsv[0] + hueShift) % 360f + 360f) % 360f
    val top = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.45f, 0.30f)))
    val bottom = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.55f, 0.14f)))
    return Brush.verticalGradient(listOf(top, bottom))
}
