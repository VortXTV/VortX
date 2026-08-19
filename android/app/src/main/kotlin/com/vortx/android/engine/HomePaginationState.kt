package com.vortx.android.engine

import com.vortx.android.model.Catalog

/** Thread-safe paging gates shared by phone and TV Home. */
internal class HomePaginationState(
    private val initialRows: Int,
    private val rowStep: Int,
) {
    private var requestedRows = initialRows
    private var boardTotal = 0
    private var reloadPending = true
    private var rowsInFlight = false
    private var rowsBeforeDispatch: Int? = null
    private val rowInFlight = mutableMapOf<Int, Int>()
    private val rowExhausted = mutableSetOf<Int>()

    /// Round-trip tracking for the full-board widen the Live surface drives (see [claimFullBoard] /
    /// [isBoardFullyLoaded]). [widenGeneration] advances on every [reset] and every full-board widen
    /// dispatch; [settledGeneration] catches up only when an [onBoardEvent] observes the board actually
    /// settled (no page still loading). They match ONLY once the widen that was dispatched has round-tripped
    /// AND settled -- so [isBoardFullyLoaded] never reports true on the mere optimistic [requestedRows] bump,
    /// nor on some unrelated event landing mid-widen. Starts unequal so nothing is "fully loaded" until a
    /// first settled board event lands.
    private var widenGeneration = 0L
    private var settledGeneration = -1L

    @Synchronized
    fun reset(): Int {
        requestedRows = initialRows
        boardTotal = 0
        reloadPending = true
        rowsInFlight = false
        rowsBeforeDispatch = null
        rowInFlight.clear()
        rowExhausted.clear()
        // A reload starts a fresh board; the prior widen's confirmation no longer applies.
        widenGeneration += 1L
        return requestedRows
    }

    @Synchronized
    fun onBoardEvent(total: Int, rows: List<Catalog>, settled: Boolean) {
        boardTotal = total
        reloadPending = false
        rowsInFlight = false
        rowsBeforeDispatch = null
        // Confirm the outstanding widen only when the board has genuinely settled (nothing still loading),
        // never on a mere "some event landed": a mid-widen event that still has loading pages must not
        // prematurely mark the board fully loaded.
        if (settled) settledGeneration = widenGeneration

        val byIndex = rows.mapNotNull { row -> row.engineIndex?.let { it to row } }.toMap()
        val iterator = rowInFlight.iterator()
        while (iterator.hasNext()) {
            val (index, dispatchedCount) = iterator.next()
            if (index >= total) {
                iterator.remove()
                continue
            }
            val row = byIndex[index] ?: continue
            if (row.pageLoading) continue
            iterator.remove()
            if (row.items.size <= dispatchedCount) rowExhausted += index
        }
    }

    @Synchronized
    fun claimMoreRows(): Int? {
        if (reloadPending || rowsInFlight || requestedRows >= boardTotal) return null
        rowsBeforeDispatch = requestedRows
        requestedRows = (requestedRows + rowStep).coerceAtMost(boardTotal)
        rowsInFlight = true
        return requestedRows
    }

    @Synchronized
    fun abortMoreRows() {
        rowsBeforeDispatch?.let { requestedRows = it }
        rowsBeforeDispatch = null
        rowsInFlight = false
    }

    /// Claim a widen of the board window to EVERY catalog (not the [rowStep] increment [claimMoreRows]
    /// takes), the Android analogue of Apple `CoreBridge.ensureLiveCatalogsLoaded`. The Live surface needs
    /// this because live-TV / channel / events catalogs are usually ordered AFTER an add-on's movie/series
    /// catalogs, so they fall outside the default [initialRows] window and never hydrate until the whole
    /// board is range-loaded. Returns the full row count to LoadRange, or null when there is nothing to do
    /// (board not yet settled, a widen already in flight, or already fully loaded). Shares the same
    /// in-flight / rollback bookkeeping as [claimMoreRows] so [abortMoreRows] reverts a failed dispatch.
    @Synchronized
    fun claimFullBoard(): Int? {
        if (reloadPending || rowsInFlight || boardTotal <= 0 || requestedRows >= boardTotal) return null
        rowsBeforeDispatch = requestedRows
        requestedRows = boardTotal
        rowsInFlight = true
        // This widen is now outstanding: [isBoardFullyLoaded] stays false until a settled [onBoardEvent]
        // confirms this exact generation, so the optimistic [requestedRows] bump above can't report done.
        widenGeneration += 1L
        return requestedRows
    }

    /// True once the board has settled with every catalog range-loaded (no widen in flight, and the widen
    /// that was dispatched has round-tripped AND settled). Lets the Live surface tell "still loading /
    /// widening" apart from a genuinely empty live set, so it shows the "install a Live TV add-on" nudge
    /// only after the whole board is loaded, never mid-load. The [settledGeneration] == [widenGeneration]
    /// gate is what keeps this false while the optimistic [requestedRows] bump is still awaiting its
    /// confirming [onBoardEvent] -- fixing the premature-true nudge flash.
    @Synchronized
    fun isBoardFullyLoaded(): Boolean =
        !reloadPending && !rowsInFlight && boardTotal > 0 && requestedRows >= boardTotal &&
            settledGeneration == widenGeneration

    @Synchronized
    fun claimNextPage(catalog: Catalog): Int? {
        val index = catalog.engineIndex ?: return null
        if (reloadPending || catalog.pageLoading || catalog.items.isEmpty()) return null
        if (index in rowExhausted || index in rowInFlight) return null
        rowInFlight[index] = catalog.items.size
        return index
    }

    @Synchronized
    fun abortNextPage(index: Int) {
        rowInFlight.remove(index)
    }

    @Synchronized
    fun rowHasNextPage(index: Int?): Boolean =
        index != null && !reloadPending && index !in rowExhausted
}
