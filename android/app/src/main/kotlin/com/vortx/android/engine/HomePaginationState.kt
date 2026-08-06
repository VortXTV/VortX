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

    @Synchronized
    fun reset(): Int {
        requestedRows = initialRows
        boardTotal = 0
        reloadPending = true
        rowsInFlight = false
        rowsBeforeDispatch = null
        rowInFlight.clear()
        rowExhausted.clear()
        return requestedRows
    }

    @Synchronized
    fun onBoardEvent(total: Int, rows: List<Catalog>) {
        boardTotal = total
        reloadPending = false
        rowsInFlight = false
        rowsBeforeDispatch = null

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
