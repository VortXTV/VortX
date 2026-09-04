package com.vortx.android.ui.tv

import androidx.compose.ui.unit.Dp
import com.vortx.android.ui.prefs.PosterStylePreferences

/**
 * Presentation-only mapping from the shared poster-style settings to TV card geometry. Keeping this
 * separate makes every TV rail and adaptive wall agree on the same live layout contract.
 */
internal data class TvPosterLayout(
    val width: Dp,
    val cornerRadius: Dp,
    val aspectRatio: Float,
    val showLabels: Boolean,
)

internal object TvPosterLayoutPolicy {
    fun layout(style: PosterStylePreferences.State): TvPosterLayout = TvPosterLayout(
        width = style.width.compactWidth,
        cornerRadius = style.radius.radius,
        aspectRatio = if (style.landscape) 16f / 9f else 2f / 3f,
        showLabels = !style.hideLabels,
    )
}
