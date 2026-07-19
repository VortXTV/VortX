package com.vortx.android.tv

import android.os.Build
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXElevation
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxShadow

/// The VortX focus treatment: the single most important interaction on a 10-foot screen.
///
/// This is a port of `CardFocusStyle` (app/SourcesShared/Theme.swift), the treatment the Apple TV app
/// uses on every card: **scale 1.08 + a warm accent ember glow + a grounding black shadow**, spring-eased
/// and Reduce-Motion aware. It is deliberately NOT the stock androidx.tv `Surface`/`Card` focus styling
/// (a white border and a flat scale), which is exactly the generic leanback-sample look the TV brief
/// bans. Focus is where VortX's brand lives on TV, so it is hand-built against the shared tokens.
object TvFocus {
    /// `CardFocusStyle.scale` default (Theme.swift): the focused card grows 8%.
    const val CARD_SCALE = 1.08f

    /// `CardFocusStyle`'s ember halo opacity, verbatim from the Swift.
    const val GLOW_ALPHA = 0.75f
}

/// The focused card's lift. Applied to the WHOLE card (art + title), like the tvOS ButtonStyle, so the
/// label grows with its poster rather than sliding out from under it.
///
/// Reduce-Motion drops the scale entirely rather than slowing it down (`lifted = active && !reduceMotion`
/// in the Swift): the glow and shadow below still mark focus, so the state stays unambiguous with no
/// movement at all.
@Composable
fun Modifier.tvFocusScale(focused: Boolean, focusedScale: Float = TvFocus.CARD_SCALE): Modifier {
    val reduced = VortXTheme.reducedMotion
    val scale by animateFloatAsState(
        targetValue = if (focused && !reduced) focusedScale else 1f,
        animationSpec = VortXMotion.heroAware(reduced),
        label = "tvFocusScale",
    )
    return this.scale(scale)
}

/// The focused card's ember glow + grounding shadow + accent ring. Applied to the ART box (the thing
/// with the shape), not the card root.
///
/// Three layers, because one is not portable:
///  1. The accent glow (`VortXElevation.glow`) is the tvOS halo: an even accent shadow that says, from
///     across the room, which card focus is on.
///  2. A black depth shadow underneath grounds the lifted card on any artwork or accent theme.
///  3. An accent ring. This is NOT in the tvOS original and NOT elevation-faking (DESIGN-SYSTEM §7 bans
///     a border used AS elevation; this is a focus indicator, which §7 does not cover). It exists because
///     Compose's colored shadows (`spotColor`/`ambientColor`) only render tinted on **API 31+** -- see
///     the note in ui/theme/Elevation.kt -- and Android TV ships plenty of API 28-30 devices (Fire TV in
///     particular). On those, layer 1 degrades to a plain black shadow, which against a dark backdrop is
///     nearly invisible, and focus would then read as scale alone. The ring guarantees an accent-colored
///     focus state on EVERY supported TV. On API 31+ it reads as the glow's crisp inner edge.
@Composable
fun Modifier.tvFocusArt(focused: Boolean, shape: Shape = VortXShapes.card): Modifier {
    val colors = VortXTheme.colors
    val reduced = VortXTheme.reducedMotion
    // One driver for all three layers, so glow/shadow/ring can never disagree about the focus state.
    val lit by animateFloatAsState(
        targetValue = if (focused) 1f else 0f,
        animationSpec = VortXMotion.heroAware(reduced),
        label = "tvFocusGlow",
    )
    // Pre-31 leans harder on the ring (the glow cannot carry the accent there); 31+ keeps the ring
    // subordinate to the glow so the treatment matches the tvOS look as closely as the platform allows.
    val ringAlpha = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) 0.55f else 0.95f
    return this
        .vortxShadow(VortXElevation.glow(colors.accent, alpha = TvFocus.GLOW_ALPHA * lit), shape)
        .vortxShadow(if (focused) VortXElevation.focus else VortXElevation.rest, shape)
        .border(width = 2.dp, color = colors.accentBright.copy(alpha = ringAlpha * lit), shape = shape)
}
