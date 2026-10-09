package com.vortx.android.ui.components

/** Mirrors Apple's measured viewport bands; direct height arithmetic avoids aspect-ratio zero height. */
internal fun cinemaDetailHeroHeightDp(widthDp: Float, viewportHeightDp: Float): Float {
    if (!widthDp.isFinite() || !viewportHeightDp.isFinite() || widthDp <= 0 || viewportHeightDp <= 0) return 420f
    val portraitPhone = widthDp < 600f && viewportHeightDp > widthDp
    return maxOf(360f, viewportHeightDp * if (portraitPhone) 0.78f else 0.60f)
}

/** Two always-present hero/action items, then exactly the optional fact items before Sources. */
internal fun cinemaDetailSourceSectionIndex(pickedReason: Boolean, ratings: Boolean, financials: Boolean, releaseDates: Boolean): Int =
    2 + listOf(pickedReason, ratings, financials, releaseDates).count { it }
