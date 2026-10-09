package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.prefs.TabSlot
import com.vortx.android.ui.prefs.isVisible

internal enum class CinemaHomeMode { FEATURED, BROWSE }

internal data class CinemaTabRoute(val tab: TabSlot, val homeMode: CinemaHomeMode)

/** Window dimensions, not physical device width: narrow multi-window tablets remain compact. */
internal fun cinemaUsesTopNavigation(widthDp: Int, heightDp: Int): Boolean =
    widthDp >= 760 && minOf(widthDp, heightDp) >= 600

internal data class CinemaCompactNavigation(val primary: List<TabSlot>, val overflow: List<TabSlot>)

/** At most five touch targets. More keeps every enabled destination reachable, never a second route. */
internal fun cinemaCompactNavigation(visible: List<TabSlot>): CinemaCompactNavigation {
    val unique = visible.distinct()
    if (unique.size <= 5) return CinemaCompactNavigation(unique, emptyList())
    val priority = listOf(TabSlot.HOME, TabSlot.DISCOVER, TabSlot.LIBRARY, TabSlot.SEARCH)
    val primary = (priority.filter { it in unique } + unique.filter { it !in priority }).take(4)
    return CinemaCompactNavigation(primary, unique.filter { it !in primary })
}

/** Resolve old saved destinations before visibility: Search folds into its actual Discover owner. */
internal fun cinemaTabRoute(
    requested: TabSlot,
    homeMode: CinemaHomeMode,
    hiddenTabs: TabBarPrefs.State,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
): CinemaTabRoute {
    val destination = if (requested == TabSlot.SEARCH && mergeDiscoverSearch) TabSlot.DISCOVER else requested
    if (!hiddenTabs.isVisible(destination)) return CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.FEATURED)
    if (destination == TabSlot.DISCOVER && mergeHomeDiscover) return CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.BROWSE)
    val mode = if (mergeHomeDiscover && !hiddenTabs.hideDiscover) homeMode else CinemaHomeMode.FEATURED
    return CinemaTabRoute(destination, mode)
}

internal fun cinemaRouteAfterHomeMergeChange(
    current: CinemaTabRoute,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
    hiddenTabs: TabBarPrefs.State,
): CinemaTabRoute {
    val requested = if (!mergeHomeDiscover && current.tab == TabSlot.HOME && current.homeMode == CinemaHomeMode.BROWSE) {
        TabSlot.DISCOVER
    } else current.tab
    return cinemaTabRoute(requested, current.homeMode, hiddenTabs, mergeHomeDiscover, mergeDiscoverSearch)
}

internal fun cinemaVisibleTabs(
    hiddenTabs: TabBarPrefs.State,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
): List<TabSlot> = TabSlot.entries.filter {
    hiddenTabs.isVisible(it) && !(mergeHomeDiscover && it == TabSlot.DISCOVER) && !(mergeDiscoverSearch && it == TabSlot.SEARCH)
}
