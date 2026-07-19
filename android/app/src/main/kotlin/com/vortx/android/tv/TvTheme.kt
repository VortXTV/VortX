package com.vortx.android.tv

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.ui.theme.LocalVortXColors
import com.vortx.android.ui.theme.LocalVortXTypeScale
import com.vortx.android.ui.theme.VortXColors
import com.vortx.android.ui.theme.VortXTypeScale
import com.vortx.android.ui.theme.vortxTypeScale

/// The 10-foot overlay on the shared VortX design system.
///
/// This file exists so the TV port needs ZERO edits inside `ui/theme/**`, which the Android phone
/// department also owns: [LocalVortXTypeScale] and the [vortxTypeScale] factory are already public, so
/// TV re-provides a re-scaled token set over the top of [com.vortx.android.ui.theme.VortXTheme] instead
/// of branching the theme itself. Colors, radii, elevation, motion and the accent system are inherited
/// UNCHANGED: a TV is a big dark screen, not a different brand.
///
/// Only the SIZES change, because the viewing distance does. `ui/theme/Typography.kt` states its scale
/// is "mobile-scaled from the web clamp() values ... not the tvOS 10-foot baseline", so the phone scale
/// is the wrong end of the clamp for a TV; these values move it back toward the tvOS baseline
/// (Theme.swift) that `app/SourcesTV` renders against.

/// The TV type scale: the same seven §2 roles, re-cut for a screen read from across a room.
///
/// Sizes are expressed in `sp` for consistency with the phone scale, but note the Android TV platform
/// pins font scale to 1.0 (there is no user font-size setting on a TV), so on TV `sp` == `dp` in
/// practice; nothing here relies on that.
fun vortxTvTypeScale(colors: VortXColors): VortXTypeScale {
    val base = vortxTypeScale(colors)
    return VortXTypeScale(
        // The living hero's title, when no clearlogo resolves. The single largest thing on the screen.
        hero = base.hero.copy(fontSize = 56.sp, lineHeight = 60.sp, letterSpacing = (-2).sp),
        screenTitle = base.screenTitle.copy(fontSize = 40.sp, lineHeight = 46.sp, letterSpacing = (-1.2).sp),
        // Rail headers. Deliberately NOT scaled as hard as the hero: the scale CONTRAST between hero and
        // rail header is what gives the 10-foot layout its hierarchy (DESIGN-SYSTEM §2 rhythm rule).
        sectionTitle = base.sectionTitle.copy(fontSize = 24.sp, lineHeight = 30.sp),
        cardTitle = base.cardTitle.copy(fontSize = 16.sp, lineHeight = 20.sp),
        body = base.body.copy(fontSize = 18.sp, lineHeight = 27.sp),
        label = base.label.copy(fontSize = 16.sp, lineHeight = 21.sp),
        eyebrow = base.eyebrow.copy(fontSize = 13.sp, lineHeight = 17.sp, letterSpacing = 2.sp),
    )
}

/// Geometry constants for the 10-foot shell.
object TvMetrics {
    /// Overscan safe insets (TV-OV). A TV can crop the outer edge of the frame, and the amount is not
    /// knowable from software, so the platform guidance is a fixed ~5% horizontal / ~5% vertical inset
    /// that all UI stays inside. 48dp/27dp is that 5% of the 960x540dp 1080p baseline.
    ///
    /// NOTE: this is a padding on CONTENT only. Background artwork (the hero backdrop) deliberately
    /// bleeds past it to the physical screen edge (TV-TR wants an opaque full-screen background);
    /// losing a few pixels of a backdrop to overscan is correct, losing a rail title is not.
    val overscanHorizontal = 48.dp
    val overscanVertical = 27.dp

    /// Poster width in a rail. Art is the canonical 2:3 (DESIGN-SYSTEM §3 "Poster card"), so this is
    /// really a HEIGHT decision: 108dp wide gives 162dp of art, and 162 + 6 + ~20 of title is the 188dp
    /// card the rail strip's budget below is solved around. Across the overscan-safe width
    /// (960 - 96 = 864dp) that lands ~7 posters in view, the density the tvOS rails read at.
    ///
    /// See [RAIL_STRIP_FRACTION] for the vertical budget, and the honesty note there.
    val posterWidth = 108.dp

    /// Gap between cards in a rail. Also the breathing room the focus glow needs so it is not clipped
    /// by the neighbouring card (the tvOS CardFocusStyle comment makes the same point).
    val railItemGap = 16.dp

    /// Fraction of the area BELOW THE TAB ROW that the rail strip occupies, leaving the rest to the
    /// living hero. Note the denominator: this is applied to the shell's content slot, not to the whole
    /// screen, because the tab row is a laid-out sibling above it.
    ///
    /// Ported from the tvOS `heroBottomStrip(height: 470)` (SharedUI.swift), re-solved rather than
    /// copied: 470/1080 = 0.435 on tvOS, but this layout spends vertical budget tvOS does not (an
    /// in-layout tab row, and explicit overscan insets tvOS gets free from the system safe area).
    ///
    /// A fraction rather than tvOS's fixed point value, but NOT because Android TV panel sizes vary in
    /// dp -- they famously do not. Android TV pins the layout viewport to ~960x540dp across 720p
    /// (tvdpi), 1080p (xhdpi) and 4K (xxxhdpi) by density convention, so 540dp tall is effectively a
    /// platform constant and the budget below is arithmetic against the real thing, not a guess at one
    /// panel. The fraction is simply the honest expression of "the strip is about half the shell".
    ///
    /// Worst case, in dp, on that 960x540dp viewport:
    ///
    ///   tab row 56  ->  content slot = 484
    ///   strip = 0.56 * 484 = 271
    ///     rail header 55 (eyebrow 17 + section 30 + pad 8)
    ///     + card 188 (art 162 + pad 6 + title 20)      = 243
    ///     + bottom overscan 27                         = 270   (1dp slack)
    ///   hero slot = 484 - 271 = 213
    ///     top overscan 27 + title 46 (1 line @40sp serif)
    ///     + meta 35 (14 pad + 21) + synopsis 72 (18 pad + 2 lines @18/27)
    ///     + gap to strip 20                            = 200   (13dp slack)
    ///
    /// That budget is why the hero folds genres INTO the meta line instead of giving them their own row
    /// (see TvHero.heroMetaLine), and why the hero title and card titles are single-line: every element
    /// here degrades by ellipsis, never by breaking the layout.
    ///
    /// HONESTY: arithmetic is not measurement. This has never been rendered -- there is no JDK on the
    /// build host, so this code has never been compiled, let alone laid out. Font metrics (Lora's real
    /// line box at 40sp) could eat that slack. The first hardening task is a screenshot pass at 720p /
    /// 1080p / 4K confirming nothing clips and the second rail peeks; this constant and [posterWidth]
    /// are the two dials to turn when it does not.
    const val RAIL_STRIP_FRACTION = 0.56f

    /// Height of the gradient in which the rail strip fades out at its top edge, so a row scrolling up
    /// out of the strip dissolves into the hero instead of clipping hard against a hard line. tvOS uses
    /// 50pt of a 1080pt viewport; this is the same proportion of the 540dp baseline.
    val railStripFade = 25.dp
}

/// Provides the TV token overlay. Wrap the TV shell's content in this INSIDE
/// [com.vortx.android.ui.theme.VortXTheme] (which supplies the colors this scale is derived from).
@Composable
fun ProvideTvTheme(content: @Composable () -> Unit) {
    val colors = LocalVortXColors.current
    CompositionLocalProvider(
        LocalVortXTypeScale provides vortxTvTypeScale(colors),
        content = content,
    )
}
