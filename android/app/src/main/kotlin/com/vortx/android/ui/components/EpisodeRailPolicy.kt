package com.vortx.android.ui.components

internal fun episodeRailTargetIndex(ids: List<String>, target: String?): Int? =
    target?.let { ids.indexOf(it).takeIf { index -> index >= 0 } }

internal fun episodeRailPageIndex(first: Int, visibleCount: Int, total: Int, forward: Boolean): Int =
    if (total <= 0) 0 else (first + (if (forward) 1 else -1) * visibleCount.coerceAtLeast(1)).coerceIn(0, total - 1)
