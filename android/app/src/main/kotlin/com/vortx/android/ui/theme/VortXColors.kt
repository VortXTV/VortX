package com.vortx.android.ui.theme

import android.graphics.Color as AndroidColor
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import kotlin.math.max
import kotlin.math.min

/// The full VortX token palette (DESIGN-SYSTEM.md §2 "Palette") as consumed values, resolved once per
/// accent/OLED combination by [vortxColors]. [canvas]/[surface1..3]/[hairline] are accent-tinted (see
/// [tintedDark], ported from `ThemeManager.tintedDark` in ThemeManager.swift) or true black under
/// [oled]; every other field either follows the live [accent] or is a fixed brand constant.
@Immutable
data class VortXColors(
    val canvas: Color,
    val surface1: Color,
    val surface2: Color,
    val surface3: Color,
    val hairline: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accent: Color,
    val accentBright: Color,
    val accentSoft: Color,
    val onAccent: Color,
    val danger: Color,
    val oled: Boolean,
)

/// Fixed brand constants (never accent- or theme-dependent): DESIGN-SYSTEM.md §2 table.
private val TextPrimary = Color(0xFFF6F1E9)
private val TextSecondary = Color(0xFFBCB1A1)
private val TextTertiary = Color(0xFF9E9485)
private val Danger = Color(0xFFDE4856)

/// Resolves the full token set for [accent] + [oled]. Mirrors `ThemeManager`'s computed properties
/// (canvas/surface1-3/hairline/onAccent) so an Android accent switch reproduces the same chrome the
/// Apple apps show for the same accent (ANDROID-PLAN.md §0 north star: "as genuine to the Apple apps
/// as possible").
fun vortxColors(accent: VortXAccent, oled: Boolean): VortXColors {
    val surfaces = if (oled) {
        OledSurfaces
    } else {
        Surfaces(
            canvas = tintedDark(accent.base, 0.085f),
            surface1 = tintedDark(accent.base, 0.130f),
            surface2 = tintedDark(accent.base, 0.175f),
            surface3 = tintedDark(accent.base, 0.225f),
            hairline = tintedDark(accent.base, 0.260f),
        )
    }
    return VortXColors(
        canvas = surfaces.canvas,
        surface1 = surfaces.surface1,
        surface2 = surfaces.surface2,
        surface3 = surfaces.surface3,
        hairline = surfaces.hairline,
        textPrimary = TextPrimary,
        textSecondary = TextSecondary,
        textTertiary = TextTertiary,
        accent = accent.base,
        accentBright = accent.bright,
        accentSoft = accent.base.copy(alpha = 0.18f),
        onAccent = onAccentFor(accent),
        danger = Danger,
        oled = oled,
    )
}

private class Surfaces(
    val canvas: Color,
    val surface1: Color,
    val surface2: Color,
    val surface3: Color,
    val hairline: Color,
)

/// True-black OLED surfaces (DESIGN-SYSTEM.md §2 "Plus OLED true-black canvas option"), identical to
/// `ThemeManager`'s `oled` branch — not accent-tinted, so every accent reads the same true black.
private val OledSurfaces = Surfaces(
    canvas = Color(0xFF000000),
    surface1 = Color(0xFF0E0E0F),
    surface2 = Color(0xFF181819),
    surface3 = Color(0xFF242426),
    hairline = Color(0xFF323234),
)

/// A dark neutral at [brightness] (0..1), hued toward [accent]'s hue at half its saturation (capped at
/// 0.34) — ports `ThemeManager.tintedDark`. Produces the warm-neutral-that-follows-the-accent chrome:
/// Ocean reads cool, Forest green, Mono near-neutral, all while staying close to black.
private fun tintedDark(accent: Color, brightness: Float): Color {
    val hsv = FloatArray(3)
    AndroidColor.colorToHSV(accent.toArgb(), hsv)
    val hue = hsv[0]
    val saturation = min(hsv[1] * 0.5f, 0.34f)
    return Color(AndroidColor.HSVToColor(floatArrayOf(hue, saturation, brightness)))
}

/// Ink that sits ON the accent fill. Ports `ThemeManager.onAccent`: VortX keeps the brand obsidian ink,
/// Ember keeps its signature warm-brown ink, every other accent picks near-black or near-white by the
/// accent's own luminance so the ink never reads "leftover orange" on a non-warm accent.
private fun onAccentFor(accent: VortXAccent): Color = when (accent.id) {
    VortXAccents.vortx.id -> Color(0xFF0F0D0A)
    VortXAccents.ember.id -> Color(0xFF1B110B)
    else -> if (luminance(accent.base) > 0.5f) Color(0xFF1A1A1C) else Color(0xFFF7F7F5)
}

/// Rec. 709 perceived luminance, matching `ThemeManager.accentLuminance`.
private fun luminance(color: Color): Float =
    max(0f, min(1f, 0.2126f * color.red + 0.7152f * color.green + 0.0722f * color.blue))

val LocalVortXColors = staticCompositionLocalOf { vortxColors(VortXAccents.default, oled = false) }
