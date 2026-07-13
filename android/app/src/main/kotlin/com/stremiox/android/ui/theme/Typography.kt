package com.stremiox.android.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import com.stremiox.android.R

/// Two families (DESIGN-SYSTEM.md §2 "Typography"): serif for the wordmark + hero/screen titles (the
/// editorial-cinema signature — the Apple apps use New York/Iowan Old Style, a proprietary Apple font
/// with no Android-licensable equivalent), system sans for everything else. Bundled serif is Lora
/// (SIL OFL 1.1, see THIRD-PARTY-NOTICES.md and res/font/) — the closest open, freely-bundleable match
/// to Iowan Old Style's warm oldstyle-serif character; Lora tops out at weight 700 (no 800 cut exists),
/// so the spec's 800 hero weight is realized as 700 Bold, the heaviest the family ships.
val VortXSerif = FontFamily(
    Font(R.font.lora_regular, FontWeight.Normal),
    Font(R.font.lora_semibold, FontWeight.SemiBold),
    Font(R.font.lora_bold, FontWeight.Bold),
)

/// System sans (Roboto on stock Android / OEM default elsewhere) — the platform default family covers
/// this role with no bundled asset, matching SF Pro's role as "the system font" on Apple platforms.
val VortXSans = FontFamily.Default

/// The DESIGN-SYSTEM §2 type-scale roles, mobile-scaled from the web `clamp()` values (Android phones
/// are viewed at arm's length like the web/iOS targets, not the tvOS 10-foot baseline, so these sit
/// close to the low end of each web clamp rather than the tvOS base sizes in Theme.swift).
data class VortXTypeScale(
    /// `hero`: 800 -1.5px serif — the Home featured hero title / splash lockup scale.
    val hero: TextStyle,
    /// `screen title`: 700 -1px serif — Detail/Discover/Library screen titles.
    val screenTitle: TextStyle,
    /// `section title`: 600 -0.3px sans — rail/section headers.
    val sectionTitle: TextStyle,
    /// `card title`: 600 sans — poster/episode/source card titles.
    val cardTitle: TextStyle,
    /// `body`: 400 sans, line-height 1.5 — synopsis, descriptions.
    val body: TextStyle,
    /// `label`: 500 sans — buttons, chips, row labels.
    val label: TextStyle,
    /// `eyebrow`: 700 sans, +1.5px tracking, UPPERCASE, accent-colored — kickers over section/hero titles.
    val eyebrow: TextStyle,
)

fun vortxTypeScale(colors: VortXColors): VortXTypeScale = VortXTypeScale(
    hero = TextStyle(
        fontFamily = VortXSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 34.sp,
        lineHeight = 38.sp,
        letterSpacing = (-1.5).sp,
        color = colors.textPrimary,
    ),
    screenTitle = TextStyle(
        fontFamily = VortXSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 28.sp,
        lineHeight = 32.sp,
        letterSpacing = (-1).sp,
        color = colors.textPrimary,
    ),
    sectionTitle = TextStyle(
        fontFamily = VortXSans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 25.sp,
        letterSpacing = (-0.3).sp,
        color = colors.textPrimary,
    ),
    cardTitle = TextStyle(
        fontFamily = VortXSans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 20.sp,
        color = colors.textPrimary,
    ),
    body = TextStyle(
        fontFamily = VortXSans,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp, // 1.5x
        color = colors.textSecondary,
    ),
    label = TextStyle(
        fontFamily = VortXSans,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 18.sp,
        color = colors.textPrimary,
    ),
    eyebrow = TextStyle(
        fontFamily = VortXSans,
        fontWeight = FontWeight.Bold,
        fontSize = 12.sp,
        lineHeight = 15.sp,
        letterSpacing = 1.5.sp,
        color = colors.accent,
        textAlign = TextAlign.Start,
    ),
)

val LocalVortXTypeScale = staticCompositionLocalOf { vortxTypeScale(vortxColors(VortXAccents.default, false)) }

/// M3's [Typography] object is still populated (see Theme.kt) so stock M3 components (buttons, text
/// fields) inherit sane defaults; screens that want the exact §2 roles read [LocalVortXTypeScale] via
/// the `VortXTheme.type` accessor in Theme.kt instead of `MaterialTheme.typography`.
fun materialTypography(colors: VortXColors): Typography {
    val scale = vortxTypeScale(colors)
    return Typography(
        headlineLarge = scale.hero,
        headlineMedium = scale.screenTitle,
        titleLarge = scale.sectionTitle,
        titleMedium = scale.cardTitle,
        bodyMedium = scale.body,
        labelLarge = scale.label,
        labelSmall = scale.eyebrow.copy(color = colors.textTertiary, letterSpacing = 0.5.sp),
    )
}
