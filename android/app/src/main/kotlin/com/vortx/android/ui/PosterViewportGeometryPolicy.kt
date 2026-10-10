package com.vortx.android.ui

import com.vortx.android.ui.prefs.PosterStylePreferences

/**
 * The small, pure geometry contract shared by touch Home rails and the TV Cinema rail.
 *
 * The source platforms use the same presentation idea: a compact width ladder for a phone, a regular
 * ladder once the measured viewport is wide enough, and one fixed cinematic width for the 10-foot
 * Continue Watching row.  Keeping that decision here prevents Home, Library and TV from growing their
 * own slightly different clamps while leaving artwork, actions and watch state in their existing owners.
 *
 * Values are density-independent layout units (dp on Android, comparable to points in the Apple source).
 * The policy deliberately has no Compose, Android window or data-layer dependency so its edge cases can be
 * exercised as a cheap JVM unit test.
 */
internal object PosterViewportGeometryPolicy {
    /** Invalid or unmeasured windows use a finite fallback; positive narrow measurements remain real. */
    const val SAFE_MIN_VIEWPORT_WIDTH = 320f

    /** Apple switches from compact to regular width at the compact/regular size-class boundary. */
    const val REGULAR_VIEWPORT_BREAKPOINT = 600f

    /** Match the existing touch edge rhythm and TV's overscan-safe inset. */
    const val TOUCH_EDGE_INSET = 20f
    const val TV_EDGE_INSET = 48f
    /** Apple `Theme.Space.sm`; keep this separate from the touch edge inset. */
    const val TOUCH_CARD_GAP = 12f
    const val TV_CARD_GAP = 20f

    /** Apple TV's shared cinematic rail baseline (`kLandscapeCardWidth`). */
    const val TV_CINEMATIC_CARD_WIDTH = 390f

    enum class Surface {
        TOUCH,
        TV,
    }

    enum class CardKind {
        CATALOG,
        CONTINUE_WATCHING,
    }

    data class Geometry(
        /** The finite viewport used by the calculation; invalid measurements use [SAFE_MIN_VIEWPORT_WIDTH]. */
        val viewportWidth: Float,
        /** Width left after the surface's safe edge insets. */
        val contentWidth: Float,
        /** The card width to use for both the cell and its content. */
        val cardWidth: Float,
        val edgeInset: Float,
        val cardGap: Float,
        val compact: Boolean,
        /** The effective art orientation supplied by the caller (CW is wide by default). */
        val landscape: Boolean,
    )

    /**
     * Resolve one card geometry from a measured viewport and the saved Poster Style width preset.
     *
     * Catalog and Continue Watching cards use the same touch width whenever the caller gives them the same
     * effective orientation. Continue Watching normally supplies wide art and preserves its progress/menu
     * semantics; it must not silently grow to a different hard clamp. TV Continue Watching is the one
     * intentional surface-specific exception: it uses Apple's 390-unit cinematic baseline, bounded by the
     * measured viewport when a TV window is unusually narrow.
     */
    fun resolve(
        viewportWidth: Float,
        widthPreset: PosterStylePreferences.WidthPreset,
        surface: Surface,
        cardKind: CardKind,
        landscape: Boolean = cardKind == CardKind.CONTINUE_WATCHING,
    ): Geometry {
        val viewport = normalizedViewportWidth(viewportWidth)
        val edgeInset = when (surface) {
            Surface.TOUCH -> TOUCH_EDGE_INSET
            Surface.TV -> TV_EDGE_INSET
        }
        val contentWidth = (viewport - 2f * edgeInset).coerceAtLeast(1f)
        val compact = surface == Surface.TOUCH && viewport < REGULAR_VIEWPORT_BREAKPOINT
        val requestedWidth = when (surface) {
            Surface.TOUCH -> if (widthPreset == PosterStylePreferences.WidthPreset.BALANCED && landscape) {
                // This is the same measured CinemaRailLayout.titleWidth contract used by Apple's
                // iOSPillMetrics.gridPosterWidth for the default landscape cards. Explicit presets
                // intentionally retain their saved compact/regular ladder instead of being resized.
                val available = contentWidth
                if (compact) {
                    maxOf(1f, (available - TOUCH_CARD_GAP) / 2f)
                } else {
                    minOf(300f, maxOf(224f, (available - 3f * TOUCH_CARD_GAP) / 4f))
                }
            } else if (compact) {
                widthPreset.compactWidth.value
            } else {
                widthPreset.regularWidth.value
            }
            Surface.TV -> if (cardKind == CardKind.CONTINUE_WATCHING) {
                TV_CINEMATIC_CARD_WIDTH
            } else {
                widthPreset.tvWidth.value
            }
        }
        // A card should never be wider than the measured safe content region. This mainly protects a
        // narrow split-screen/TV window; normal phone, tablet and TV values retain their source baselines.
        val cardWidth = requestedWidth
            .takeIf { it.isFinite() && it > 0f }
            ?.coerceAtMost(contentWidth)
            ?: contentWidth

        return Geometry(
            viewportWidth = viewport,
            contentWidth = contentWidth,
            cardWidth = cardWidth,
            edgeInset = edgeInset,
            cardGap = if (surface == Surface.TV) TV_CARD_GAP else TOUCH_CARD_GAP,
            compact = compact,
            landscape = landscape,
        )
    }

    /** Guard NaN, infinity, zero and negative measurements before any subtraction or clamp. */
    fun normalizedViewportWidth(viewportWidth: Float): Float =
        viewportWidth.takeIf { it.isFinite() && it > 0f } ?: SAFE_MIN_VIEWPORT_WIDTH
}
