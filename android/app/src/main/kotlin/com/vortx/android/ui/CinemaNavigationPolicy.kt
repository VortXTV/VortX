package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.prefs.TabSlot
import com.vortx.android.ui.prefs.isVisible

internal enum class CinemaHomeMode { FEATURED, BROWSE }

internal data class CinemaTabRoute(val tab: TabSlot, val homeMode: CinemaHomeMode)

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
