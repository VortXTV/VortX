package com.vortx.android.ui.viewmodel

/** Keeps only the newest source-snapshot cache decoration eligible to update the detail screen. */
internal class CacheCheckGenerationGate {
    private val lock = Any()
    private var generation = 0L

    fun begin(): Long = synchronized(lock) {
        generation += 1
        generation
    }

    fun isCurrent(candidate: Long): Boolean = synchronized(lock) { candidate == generation }
}
