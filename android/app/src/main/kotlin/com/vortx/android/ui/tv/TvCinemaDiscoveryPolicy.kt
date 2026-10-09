package com.vortx.android.ui.tv

import com.vortx.android.ui.prefs.TabBarPrefs

internal data class TvCinemaRoute(val destination: TvDestination, val homeBrowseSelected: Boolean = false)

internal fun tvCinemaDestinations(
    hidden: TabBarPrefs.State,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
): List<TvDestination> = TvDestination.entries.filter {
    when (it) {
        TvDestination.DISCOVER -> !mergeHomeDiscover && !hidden.hideDiscover
        TvDestination.SEARCH -> !mergeDiscoverSearch && !hidden.hideSearch
        TvDestination.LIVE -> !hidden.hideLive
        TvDestination.LIBRARY -> !hidden.hideLibrary
        else -> true
    }
}

/** Resolve the real Search owner before hide flags, matching the touch Cinema routing policy. */
internal fun tvCinemaRoute(
    requested: TvDestination,
    homeBrowseSelected: Boolean,
    hidden: TabBarPrefs.State,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
): TvCinemaRoute {
    val destination = if (requested == TvDestination.SEARCH && mergeDiscoverSearch) TvDestination.DISCOVER else requested
    if (destination == TvDestination.DISCOVER) {
        if (hidden.hideDiscover) return TvCinemaRoute(TvDestination.HOME)
        return if (mergeHomeDiscover) TvCinemaRoute(TvDestination.HOME, true) else TvCinemaRoute(destination)
    }
    if (destination !in tvCinemaDestinations(hidden, mergeHomeDiscover, mergeDiscoverSearch)) return TvCinemaRoute(TvDestination.HOME)
    return TvCinemaRoute(destination, destination == TvDestination.HOME && homeBrowseSelected && mergeHomeDiscover && !hidden.hideDiscover)
}

internal fun tvCinemaRouteAfterPreferencesChange(
    current: TvCinemaRoute,
    previousMergeHomeDiscover: Boolean,
    hidden: TabBarPrefs.State,
    mergeHomeDiscover: Boolean,
    mergeDiscoverSearch: Boolean,
): TvCinemaRoute {
    val requested = if (previousMergeHomeDiscover && !mergeHomeDiscover && current.destination == TvDestination.HOME && current.homeBrowseSelected) {
        TvDestination.DISCOVER
    } else current.destination
    return tvCinemaRoute(requested, current.homeBrowseSelected, hidden, mergeHomeDiscover, mergeDiscoverSearch)
}
