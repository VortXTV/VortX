package com.vortx.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider

/// The VortX design-system layer (DESIGN-SYSTEM.md §2-3), wired two ways at once:
///  1. [LocalVortXColors] / [LocalVortXTypeScale] carry the exact token values every VortX-native
///     component (`ui/components/*`) reads via the [VortXTheme] accessor object below.
///  2. A mapped M3 [androidx.compose.material3.ColorScheme] + [androidx.compose.material3.Typography]
///     go into [MaterialTheme] itself, so stock M3 widgets (buttons, text fields, snackbars — anything
///     a screen reaches for before its own VortX component exists) still inherit VortX colors instead
///     of the M3 baseline purple.
///
/// The app is dark-only by design (DESIGN-SYSTEM.md §1: "the chrome is warm monochrome and recedes" —
/// there is no light variant to switch to), so [accentId]/[oled] are the only live inputs; there is no
/// `isSystemInDarkTheme()` branch to a light scheme.
@Composable
fun VortXTheme(
    accentId: String = VortXAccents.default.id,
    oled: Boolean = false,
    materialYou: Boolean = false,
    content: @Composable () -> Unit,
) {
    @Suppress("UNUSED_VARIABLE") val systemDark = isSystemInDarkTheme() // read, not branched on — see kdoc above
    val accent = if (materialYou) materialYouAccent() else VortXAccents.byId(accentId)
    val colors = vortxColors(accent, oled)
    val typeScale = vortxTypeScale(colors)

    val materialColorScheme = darkColorScheme(
        primary = colors.accent,
        onPrimary = colors.onAccent,
        primaryContainer = colors.accentSoft,
        onPrimaryContainer = colors.accentBright,
        secondary = colors.accentBright,
        onSecondary = colors.onAccent,
        background = colors.canvas,
        onBackground = colors.textPrimary,
        surface = colors.surface1,
        onSurface = colors.textPrimary,
        surfaceVariant = colors.surface2,
        onSurfaceVariant = colors.textSecondary,
        surfaceContainerHighest = colors.surface3,
        outline = colors.hairline,
        outlineVariant = colors.hairline,
        error = colors.danger,
        onError = colors.textPrimary,
    )

    CompositionLocalProvider(
        LocalVortXColors provides colors,
        LocalVortXTypeScale provides typeScale,
        LocalReducedMotion provides rememberReducedMotion(),
    ) {
        MaterialTheme(
            colorScheme = materialColorScheme,
            typography = materialTypography(colors),
            content = content,
        )
    }
}

/// `VortXTheme.colors` / `.type` — the DESIGN-SYSTEM token accessor, parallel to `MaterialTheme.*`.
/// Every VortX-native component reads through here rather than `MaterialTheme.colorScheme` directly,
/// so a component never silently drifts onto an M3 default color the mapping above didn't cover.
object VortXTheme {
    val colors: VortXColors
        @Composable get() = LocalVortXColors.current

    val type: VortXTypeScale
        @Composable get() = LocalVortXTypeScale.current

    val spacing get() = VortXSpacing
    val radius get() = VortXRadius
    val shapes get() = VortXShapes
    val elevation get() = VortXElevation
    val motion get() = VortXMotion

    val reducedMotion: Boolean
        @Composable get() = LocalReducedMotion.current
}
