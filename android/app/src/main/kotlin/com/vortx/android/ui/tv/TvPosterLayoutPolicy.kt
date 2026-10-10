package com.vortx.android.ui.tv

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.PosterViewportGeometryPolicy
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
    fun layout(
        style: PosterStylePreferences.State,
        viewportWidth: Float = DEFAULT_TV_VIEWPORT_WIDTH,
        cardKind: PosterViewportGeometryPolicy.CardKind = PosterViewportGeometryPolicy.CardKind.CATALOG,
    ): TvPosterLayout {
        val geometry = PosterViewportGeometryPolicy.resolve(
            viewportWidth = viewportWidth,
            widthPreset = style.width,
            surface = PosterViewportGeometryPolicy.Surface.TV,
            cardKind = cardKind,
            landscape = style.landscape || cardKind == PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
        )
        return TvPosterLayout(
            width = geometry.cardWidth.dp,
            cornerRadius = style.radius.radius,
            aspectRatio = if (style.landscape || geometry.landscape) 16f / 9f else 2f / 3f,
            showLabels = !style.hideLabels,
        )
    }

    /** The TV Home/Library Continue Watching rail uses Apple's 390-unit cinematic baseline. */
    fun continueWatchingWidth(viewportWidth: Float = DEFAULT_TV_VIEWPORT_WIDTH): Dp =
        layout(
            style = PosterStylePreferences.State(),
            viewportWidth = viewportWidth,
            cardKind = PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
        ).width

    private const val DEFAULT_TV_VIEWPORT_WIDTH = 1280f
}
