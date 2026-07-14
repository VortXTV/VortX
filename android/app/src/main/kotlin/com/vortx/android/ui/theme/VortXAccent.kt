package com.vortx.android.ui.theme

import android.os.Build
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/// One selectable accent: [base] recolors focus / selection / primary action / progress everywhere;
/// [bright] is the focus-glow / hover peak (DESIGN-SYSTEM.md §2 "Palette", "Themeable accents").
/// Mirrors `ThemeManager.AccentOption` (app/SourcesShared/ThemeManager.swift) value-for-value so the
/// Android accent list reads identically to the Apple apps' Settings → Appearance picker.
data class VortXAccent(val id: String, val label: String, val base: Color, val bright: Color)

/// The nine curated accents (VortX gold is the shipping default, Ember is the retired StremioX
/// accent kept for anyone who preferred it) plus the optional "Material You" tenth slot, which is
/// resolved at call time from the platform's dynamic color (Android 12+) rather than a fixed value —
/// see [materialYouAccent]. Hex values below were derived from the Apple sRGB tuples in
/// ThemeManager.swift (`themeRGB(r,g,b)` * 255, rounded) so both platforms show the same colors.
object VortXAccents {
    val vortx = VortXAccent("vortx", "VortX", Color(0xFFD97706), Color(0xFFF59E0B))
    val ember = VortXAccent("ember", "Ember", Color(0xFFF2784B), Color(0xFFFF9163))
    val ocean = VortXAccent("ocean", "Ocean", Color(0xFF4C90E2), Color(0xFF6FB0FB))
    val forest = VortXAccent("forest", "Forest", Color(0xFF60B471), Color(0xFF7AD48D))
    val royal = VortXAccent("royal", "Royal", Color(0xFF9473E6), Color(0xFFB18FFB))
    val crimson = VortXAccent("crimson", "Crimson", Color(0xFFE24F5B), Color(0xFFFB6B76))
    val gold = VortXAccent("gold", "Gold", Color(0xFFE2B44A), Color(0xFFFACD66))
    val rose = VortXAccent("rose", "Rose", Color(0xFFED739E), Color(0xFFFF8FB5))
    val mono = VortXAccent("mono", "Mono", Color(0xFFD1CCC2), Color(0xFFEBE8E1))

    /// Sentinel id for the platform-sourced "Material You" accent (ANDROID-PLAN.md §0: "offered as
    /// one optional accent theme... alongside the eight VortX accents; ... accent only, never
    /// restyles layout or surfaces"). Its [VortXAccent.base]/[bright] are placeholders — real call
    /// sites resolve the live color via [materialYouAccent], never this static entry, because dynamic
    /// color is only available from a [android.content.Context] at composition time.
    const val MATERIAL_YOU_ID = "material_you"

    /// Curated accents in picker order. Does NOT include Material You — that entry is appended by
    /// call sites that have a [android.content.Context] (see [materialYouAccent]), since its label
    /// needs no context but its actual colors do.
    val curated: List<VortXAccent> = listOf(vortx, ember, ocean, forest, royal, crimson, gold, rose, mono)

    val default: VortXAccent = vortx

    fun byId(id: String): VortXAccent = curated.firstOrNull { it.id == id } ?: default
}

/// Resolves the live Material You accent from the platform's dynamic color palette (Android 12+ /
/// API 31, [Build.VERSION_CODES.S]). Below API 31, or if dynamic color is otherwise unavailable,
/// falls back to the VortX gold default so callers never need their own API-level branch. Per
/// ANDROID-PLAN.md §0, Material You supplies ONLY this accent pair — never surfaces, never layout —
/// so [VortXColors] always derives its warm-neutral surfaces from the accent hue via [vortxColors],
/// identically whether the accent came from Material You or a curated swatch.
@Composable
fun materialYouAccent(): VortXAccent {
    val context = LocalContext.current
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return VortXAccents.default
    val dynamic = dynamicDarkColorScheme(context)
    return VortXAccent(
        id = VortXAccents.MATERIAL_YOU_ID,
        label = "Material You",
        base = dynamic.primary,
        bright = dynamic.primaryContainer,
    )
}
