package com.vortx.android.ui.tv

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

/** Only the ordinary catalog callback uses this policy. Resume/history/local routes keep their owner. */
internal fun tvCatalogOpensQuickView(item: MetaItem, enabled: Boolean): Boolean =
    enabled && item.type in setOf(MediaType.MOVIE, MediaType.SERIES) &&
        item.progress == null && item.resumeSeconds == null && item.preferredEpisode == null &&
        item.continueWatchingPermit == null && item.continueWatchingAdmission == null &&
        item.continueWatchingUnavailableMessage == null && item.continueWatchingActivityAtMillis == null

internal data class TvQuickViewSelection(val item: MetaItem, val owner: ContinueWatchingOwner)

internal fun tvQuickWatchMatchesDetail(selection: TvQuickViewSelection?, detail: MetaItem, currentOwner: ContinueWatchingOwner): Boolean =
    selection != null && selection.item.id == detail.id && selection.item.type == detail.type && selection.owner == currentOwner

/** The production callbacks share one immutable presentation owner, including its session revision. */
internal class TvQuickViewActions(
    private val selection: TvQuickViewSelection,
    private val store: WatchlistStore,
    private val currentOwner: () -> ContinueWatchingOwner,
    private val onClose: () -> Unit,
    private val onWatch: (MetaItem, ContinueWatchingOwner) -> Unit,
    private val onDetails: (MetaItem) -> Unit,
) {
    fun ownsCurrentPresentation(): Boolean = currentOwner() == selection.owner

    fun watch(): Boolean = navigate { onWatch(selection.item, selection.owner) }
    fun details(): Boolean = navigate { onDetails(selection.item) }

    private fun navigate(action: () -> Unit): Boolean {
        if (!ownsCurrentPresentation()) return false
        onClose()
        if (!ownsCurrentPresentation()) return false
        action()
        return true
    }

    /** Called in the remote click, before launching the asynchronous mutation. */
    fun captureWatchlistToggle(): WatchlistStore.ToggleIntent {
        check(ownsCurrentPresentation()) { "Account or profile changed. Open this title again." }
        check(WatchlistStore.isSafeId(selection.item.id)) { "Watchlist is unavailable for this title." }
        return store.captureToggle(selection.item)
    }

    suspend fun toggleWatchlist(intent: WatchlistStore.ToggleIntent): Boolean {
        check(ownsCurrentPresentation()) { "Account or profile changed. Open this title again." }
        val added = store.toggle(intent)
        check(ownsCurrentPresentation()) { "Account or profile changed. Open this title again." }
        return added
    }
}
