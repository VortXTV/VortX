package com.vortx.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/// A soft, colored drop shadow spec (DESIGN-SYSTEM.md §2 "Elevation (NO borders for elevation)").
/// [elevation] is the shadow-casting depth passed to [androidx.compose.ui.draw.shadow]; [color] tints
/// it. Colored shadow tinting (`spotColor`/`ambientColor`) only visually renders on API 31+ (Compose
/// draws a plain black shadow of the same shape/depth below that) — a framework limitation, not a
/// VortX choice; every elevation still reads as "lifted," just without the accent tint pre-S.
data class VortXElevationSpec(val elevation: Dp, val color: Color)

object VortXElevation {
    /// `rest 0 7px 12px rgba(0,0,0,.32)` — the default card/row shadow.
    val rest = VortXElevationSpec(elevation = 10.dp, color = Color.Black.copy(alpha = 0.32f))

    /// `focus 0 10px 16px rgba(0,0,0,.45)` — hover/press/focus lift.
    val focus = VortXElevationSpec(elevation = 14.dp, color = Color.Black.copy(alpha = 0.45f))

    /// `glow-accent 0 0 18px rgba(217,119,6,.6)` — the accent glow on a focused/selected poster or the
    /// primary button's hover halo. Callers pass the live accent color; [glow] here is the VortX-gold
    /// default for previews/fallbacks only.
    fun glow(accent: Color, alpha: Float = 0.6f) = VortXElevationSpec(elevation = 18.dp, color = accent.copy(alpha = alpha))
}

/// Applies a [VortXElevationSpec] as a shape-clipped colored shadow. Never use a 1px border to fake
/// elevation (DESIGN-SYSTEM.md §7 anti-pattern) — this is the one sanctioned path to "lifted."
fun Modifier.vortxShadow(spec: VortXElevationSpec, shape: Shape = RoundedCornerShape(VortXRadius.card)): Modifier =
    this.shadow(elevation = spec.elevation, shape = shape, ambientColor = spec.color, spotColor = spec.color)
