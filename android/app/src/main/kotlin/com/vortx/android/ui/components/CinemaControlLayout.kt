package com.vortx.android.ui.components

import androidx.compose.runtime.staticCompositionLocalOf

/** Width-local control density: a tablet in a narrow split window remains compact. */
internal data class CinemaControlLayout(val spacious: Boolean) {
    val maxContentWidthDp: Int = 1120
    val cardPaddingDp: Int = if (spacious) 24 else 16
    val cardGapDp: Int = if (spacious) 20 else 16
    val addonLogoDp: Int = if (spacious) 64 else 48
}

internal fun cinemaControlLayout(availableWidthDp: Float): CinemaControlLayout =
    CinemaControlLayout(availableWidthDp.isFinite() && availableWidthDp >= 600f)

internal val LocalCinemaControlLayout = staticCompositionLocalOf { CinemaControlLayout(false) }
