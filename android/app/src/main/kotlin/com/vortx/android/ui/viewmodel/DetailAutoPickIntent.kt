package com.vortx.android.ui.viewmodel

/** A queued play intent survives source loading, but never survives dismissal of its route. */
internal class DetailAutoPickIntent {
    @Volatile var isArmed = false
        private set
    @Volatile private var generation = 0L

    fun setArmed(armed: Boolean) {
        generation += 1L
        isArmed = armed
    }

    fun consume(selectionReady: Boolean): Long? {
        if (!selectionReady || !isArmed) return null
        isArmed = false
        return generation
    }

    fun accepts(lease: Long): Boolean = generation == lease
}
