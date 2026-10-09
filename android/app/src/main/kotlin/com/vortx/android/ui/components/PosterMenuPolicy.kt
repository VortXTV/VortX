package com.vortx.android.ui.components

import com.vortx.android.library.NativeWatchlistCodec
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

internal enum class PosterCatalogAction { QUICK_VIEW, WATCHLIST, MARK_WATCHED, MARK_UNWATCHED }

/** CW cards never acquire ordinary catalog mutations merely by being rendered in a grid. */
internal fun cinemaPosterMenu(item: MetaItem, continueWatching: Boolean): PosterCardMenu = when {
    continueWatching -> PosterCardMenu.CONTINUE_WATCHING
    item.continueWatchingPermit != null || item.continueWatchingAdmission != null || item.continueWatchingUnavailableMessage != null -> PosterCardMenu.NONE
    item.type !in setOf(MediaType.MOVIE, MediaType.SERIES) -> PosterCardMenu.NONE
    else -> PosterCardMenu.CATALOG
}

internal fun posterCatalogActions(
    item: MetaItem,
    quickViewAvailable: Boolean,
    watchlistAvailable: Boolean,
    watchedAvailable: Boolean,
): List<PosterCatalogAction> {
    if (cinemaPosterMenu(item, continueWatching = false) != PosterCardMenu.CATALOG) return emptyList()
    return buildList {
        if (quickViewAvailable) add(PosterCatalogAction.QUICK_VIEW)
        if (watchlistAvailable && runCatching { NativeWatchlistCodec.field(item.id, item.type.id) }.isSuccess) {
            add(PosterCatalogAction.WATCHLIST)
        }
        if (watchedAvailable) {
            add(PosterCatalogAction.MARK_WATCHED)
            add(PosterCatalogAction.MARK_UNWATCHED)
        }
    }
}

/** Capture in the event caller, not inside the queued coroutine that eventually executes it. */
internal fun <Intent, Result> capturePosterAction(capture: () -> Intent, execute: suspend (Intent) -> Result): suspend () -> Result {
    val intent = capture()
    return { execute(intent) }
}
