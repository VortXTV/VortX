package com.vortx.android.engine

/** Unrelated display/ranking collaborators, not SourceIndex admission implementations. */
data class SourceContributorSettlement(val requestGeneration: Long = -1L, val settled: Boolean = true)
object StreamRanking {
    fun sizeForSort(source: com.vortx.android.model.StreamSource): Double = 0.0
    fun qualityLabel(source: com.vortx.android.model.StreamSource): String = "Other"
    fun seedersForSort(source: com.vortx.android.model.StreamSource): Int = -1
}
